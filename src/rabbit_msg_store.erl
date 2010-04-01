%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_msg_store).

-behaviour(gen_server2).

-export([start_link/4, write/4, read/3, contains/2, remove/2, release/2,
         sync/3, client_init/1, client_terminate/1]).

-export([sync/1, gc_done/4, set_maximum_since_use/2]). %% internal

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, handle_pre_hibernate/1]).

-define(SYNC_INTERVAL,         5). %% milliseconds

-define(GEOMETRIC_P, 0.3). %% parameter to geometric distribution rng

%%----------------------------------------------------------------------------

-record(msstate,
        { dir,                    %% store directory
          index_module,           %% the module for index ops
          index_state,            %% where are messages?
          current_file,           %% current file name as number
          current_file_handle,    %% current file handle
                                  %% since the last fsync?
          file_handle_cache,      %% file handle cache
          on_sync,                %% pending sync requests
          sync_timer_ref,         %% TRef for our interval timer
          sum_valid_data,         %% sum of valid data in all files
          sum_file_size,          %% sum of file sizes
          pending_gc_completion,  %% things to do once GC completes
          gc_active,              %% is the GC currently working?
          gc_pid,                 %% pid of our GC
          file_handles_ets,       %% tid of the shared file handles table
          file_summary_ets,       %% tid of the file summary table
          dedup_cache_ets,        %% tid of dedup cache table
          cur_file_cache_ets      %% tid of current file cache table
        }).

-record(client_msstate,
        { file_handle_cache,
          index_state,
          index_module,
          dir,
          file_handles_ets,
          file_summary_ets,
          dedup_cache_ets,
          cur_file_cache_ets
        }).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(server() :: pid() | atom()).
-type(msg_id() :: binary()).
-type(msg() :: any()).
-type(file_path() :: any()).
-type(file_num() :: non_neg_integer()).
-type(client_msstate() :: #client_msstate { file_handle_cache  :: dict(),
                                            index_state        :: any(),
                                            index_module       :: atom(),
                                            dir                :: file_path(),
                                            file_handles_ets   :: tid(),
                                            file_summary_ets   :: tid(),
                                            dedup_cache_ets    :: tid(),
                                            cur_file_cache_ets :: tid() }).

-spec(start_link/4 ::
      (atom(), file_path(),
       (fun ((A) -> 'finished' | {msg_id(), non_neg_integer(), A})), A) ->
             {'ok', pid()} | 'ignore' | {'error', any()}).
-spec(write/4 :: (server(), msg_id(), msg(), client_msstate()) ->
                      {'ok', client_msstate()}).
-spec(read/3 :: (server(), msg_id(), client_msstate()) ->
                     {{'ok', msg()} | 'not_found', client_msstate()}).
-spec(contains/2 :: (server(), msg_id()) -> boolean()).
-spec(remove/2 :: (server(), [msg_id()]) -> 'ok').
-spec(release/2 :: (server(), [msg_id()]) -> 'ok').
-spec(sync/3 :: (server(), [msg_id()], fun (() -> any())) -> 'ok').
-spec(gc_done/4 :: (server(), non_neg_integer(), file_num(), file_num()) -> 'ok').
-spec(set_maximum_since_use/2 :: (server(), non_neg_integer()) -> 'ok').
-spec(client_init/1 :: (server()) -> client_msstate()).
-spec(client_terminate/1 :: (client_msstate()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-include("rabbit_msg_store.hrl").

%% We run GC whenever (garbage / sum_file_size) > ?GARBAGE_FRACTION
%% It is not recommended to set this to < 0.5
-define(GARBAGE_FRACTION,      0.5).

%% The components:
%%
%% MsgLocation: this is a mapping from MsgId to #msg_location{}:
%%              {MsgId, RefCount, File, Offset, TotalSize}
%%              By default, it's in ets, but it's also pluggable.
%% FileSummary: this is an ets table which contains:
%%              {File, ValidTotalSize, ContiguousTop, Left, Right}
%%
%% The basic idea is that messages are appended to the current file up
%% until that file becomes too big (> file_size_limit). At that point,
%% the file is closed and a new file is created on the _right_ of the
%% old file which is used for new messages. Files are named
%% numerically ascending, thus the file with the lowest name is the
%% eldest file.
%%
%% We need to keep track of which messages are in which files (this is
%% the MsgLocation mapping); how much useful data is in each file and
%% which files are on the left and right of each other. This is the
%% purpose of the FileSummary table.
%%
%% As messages are removed from files, holes appear in these
%% files. The field ValidTotalSize contains the total amount of useful
%% data left in the file, whilst ContiguousTop contains the amount of
%% valid data right at the start of each file. These are needed for
%% garbage collection.
%%
%% When we discover that a file is now empty, we delete it. When we
%% discover that it can be combined with the useful data in either its
%% left or right neighbour, and overall, across all the files, we have
%% ((the amount of garbage) / (the sum of all file sizes)) >
%% ?GARBAGE_FRACTION, we start a garbage collection run concurrently,
%% which will compact the two files together. This keeps disk
%% utilisation high and aids performance. We deliberately do this
%% lazily in order to prevent doing GC on files which are soon to be
%% emptied (and hence deleted) soon.
%%
%% Given the compaction between two files, the left file (i.e. elder
%% file) is considered the ultimate destination for the good data in
%% the right file. If necessary, the good data in the left file which
%% is fragmented throughout the file is written out to a temporary
%% file, then read back in to form a contiguous chunk of good data at
%% the start of the left file. Thus the left file is garbage collected
%% and compacted. Then the good data from the right file is copied
%% onto the end of the left file. MsgLocation and FileSummary tables
%% are updated.
%%
%% On startup, we scan the files we discover, dealing with the
%% possibilites of a crash have occured during a compaction (this
%% consists of tidyup - the compaction is deliberately designed such
%% that data is duplicated on disk rather than risking it being lost),
%% and rebuild the FileSummary ets table and MsgLocation mapping.
%%
%% So, with this design, messages move to the left. Eventually, they
%% should end up in a contiguous block on the left and are then never
%% rewritten. But this isn't quite the case. If in a file there is one
%% message that is being ignored, for some reason, and messages in the
%% file to the right and in the current block are being read all the
%% time then it will repeatedly be the case that the good data from
%% both files can be combined and will be written out to a new
%% file. Whenever this happens, our shunned message will be rewritten.
%%
%% So, provided that we combine messages in the right order,
%% (i.e. left file, bottom to top, right file, bottom to top),
%% eventually our shunned message will end up at the bottom of the
%% left file. The compaction/combining algorithm is smart enough to
%% read in good data from the left file that is scattered throughout
%% (i.e. C and D in the below diagram), then truncate the file to just
%% above B (i.e. truncate to the limit of the good contiguous region
%% at the start of the file), then write C and D on top and then write
%% E, F and G from the right file on top. Thus contiguous blocks of
%% good data at the bottom of files are not rewritten (yes, this is
%% the data the size of which is tracked by the ContiguousTop
%% variable. Judicious use of a mirror is required).
%%
%% +-------+    +-------+         +-------+
%% |   X   |    |   G   |         |   G   |
%% +-------+    +-------+         +-------+
%% |   D   |    |   X   |         |   F   |
%% +-------+    +-------+         +-------+
%% |   X   |    |   X   |         |   E   |
%% +-------+    +-------+         +-------+
%% |   C   |    |   F   |   ===>  |   D   |
%% +-------+    +-------+         +-------+
%% |   X   |    |   X   |         |   C   |
%% +-------+    +-------+         +-------+
%% |   B   |    |   X   |         |   B   |
%% +-------+    +-------+         +-------+
%% |   A   |    |   E   |         |   A   |
%% +-------+    +-------+         +-------+
%%   left         right             left
%%
%% From this reasoning, we do have a bound on the number of times the
%% message is rewritten. From when it is inserted, there can be no
%% files inserted between it and the head of the queue, and the worst
%% case is that everytime it is rewritten, it moves one position lower
%% in the file (for it to stay at the same position requires that
%% there are no holes beneath it, which means truncate would be used
%% and so it would not be rewritten at all). Thus this seems to
%% suggest the limit is the number of messages ahead of it in the
%% queue, though it's likely that that's pessimistic, given the
%% requirements for compaction/combination of files.
%%
%% The other property is that we have is the bound on the lowest
%% utilisation, which should be 50% - worst case is that all files are
%% fractionally over half full and can't be combined (equivalent is
%% alternating full files and files with only one tiny message in
%% them).
%%
%% Messages are reference-counted. When a message with the same id is
%% written several times we only store it once, and only remove it
%% from the store when it has been removed the same number of
%% times.
%%
%% The reference counts do not persist. Therefore the initialisation
%% function must be provided with a generator that produces ref count
%% deltas for all recovered messages.
%%
%% Read messages with a reference count greater than one are entered
%% into a message cache. The purpose of the cache is not especially
%% performance, though it can help there too, but prevention of memory
%% explosion. It ensures that as messages with a high reference count
%% are read from several processes they are read back as the same
%% binary object rather than multiples of identical binary
%% objects.
%%
%% Reads can be performed directly by clients without calling to the
%% server. This is safe because multiple file handles can be used to
%% read files. However, locking is used by the concurrent GC to make
%% sure that reads are not attempted from files which are in the
%% process of being garbage collected.
%%
%% The server automatically defers reads, removes and contains calls
%% that occur which refer to files which are currently being
%% GC'd. Contains calls are only deferred in order to ensure they do
%% not overtake removes.
%%
%% The current file to which messages are being written has a
%% write-back cache. This is written to immediately by the client and
%% can be read from by the client too. This means that there are only
%% ever writes made to the current file, thus eliminating delays due
%% to flushing write buffers in order to be able to safely read from
%% the current file. The one exception to this is that on start up,
%% the cache is not populated with msgs found in the current file, and
%% thus in this case only, reads may have to come from the file
%% itself. The effect of this is that even if the msg_store process is
%% heavily overloaded, clients can still write and read messages with
%% very low latency and not block at all.

%%----------------------------------------------------------------------------
%% public API
%%----------------------------------------------------------------------------

start_link(Server, Dir, MsgRefDeltaGen, MsgRefDeltaGenInit) ->
    gen_server2:start_link({local, Server}, ?MODULE,
                           [Server, Dir, MsgRefDeltaGen, MsgRefDeltaGenInit],
                           [{timeout, infinity}]).

write(Server, MsgId, Msg, CState =
          #client_msstate { cur_file_cache_ets = CurFileCacheEts }) ->
    ok = add_to_cache(CurFileCacheEts, MsgId, Msg),
    {gen_server2:cast(Server, {write, MsgId, Msg}), CState}.

read(Server, MsgId, CState =
         #client_msstate { dedup_cache_ets = DedupCacheEts,
                           cur_file_cache_ets = CurFileCacheEts }) ->
    %% 1. Check the dedup cache
    case fetch_and_increment_cache(DedupCacheEts, MsgId) of
        not_found ->
            %% 2. Check the cur file cache
            case ets:lookup(CurFileCacheEts, MsgId) of
                [] ->
                    Defer = fun() -> {gen_server2:pcall(
                                        Server, 2, {read, MsgId}, infinity),
                                      CState} end,
                    case index_lookup(MsgId, CState) of
                        not_found   -> Defer();
                        MsgLocation -> client_read1(Server, MsgLocation, Defer,
                                                    CState)
                    end;
                [{MsgId, Msg, _CacheRefCount}] ->
                    %% Although we've found it, we don't know the
                    %% refcount, so can't insert into dedup cache
                    {{ok, Msg}, CState}
            end;
        Msg ->
            {{ok, Msg}, CState}
    end.

contains(Server, MsgId) -> gen_server2:call(Server, {contains, MsgId}, infinity).
remove(Server, MsgIds)  -> gen_server2:cast(Server, {remove, MsgIds}).
release(Server, MsgIds) -> gen_server2:cast(Server, {release, MsgIds}).
sync(Server, MsgIds, K) -> gen_server2:cast(Server, {sync, MsgIds, K}).
sync(Server)            -> gen_server2:pcast(Server, 8, sync). %% internal

gc_done(Server, Reclaimed, Source, Destination) ->
    gen_server2:pcast(Server, 8, {gc_done, Reclaimed, Source, Destination}).

set_maximum_since_use(Server, Age) ->
    gen_server2:pcast(Server, 8, {set_maximum_since_use, Age}).

client_init(Server) ->
    {IState, IModule, Dir, FileHandlesEts, FileSummaryEts, DedupCacheEts,
     CurFileCacheEts} = gen_server2:call(Server, new_client_state, infinity),
    #client_msstate { file_handle_cache  = dict:new(),
                      index_state        = IState,
                      index_module       = IModule,
                      dir                = Dir,
                      file_handles_ets   = FileHandlesEts,
                      file_summary_ets   = FileSummaryEts,
                      dedup_cache_ets    = DedupCacheEts,
                      cur_file_cache_ets = CurFileCacheEts }.

client_terminate(CState) ->
    close_all_handles(CState),
    ok.

%%----------------------------------------------------------------------------
%% Client-side-only helpers
%%----------------------------------------------------------------------------

add_to_cache(CurFileCacheEts, MsgId, Msg) ->
    case ets:insert_new(CurFileCacheEts, {MsgId, Msg, 1}) of
        true ->
            ok;
        false ->
            try
                ets:update_counter(CurFileCacheEts, MsgId, {3, +1}),
                ok
            catch error:badarg -> add_to_cache(CurFileCacheEts, MsgId, Msg)
            end
    end.

client_read1(Server, #msg_location { msg_id = MsgId, file = File } =
                 MsgLocation, Defer, CState =
                 #client_msstate { file_summary_ets = FileSummaryEts }) ->
    case ets:lookup(FileSummaryEts, File) of
        [] -> %% File has been GC'd and no longer exists. Go around again.
            read(Server, MsgId, CState);
        [#file_summary { locked = Locked, right = Right }] ->
            client_read2(Server, Locked, Right, MsgLocation, Defer, CState)
    end.

client_read2(_Server, false, undefined,
             #msg_location { msg_id = MsgId, ref_count = RefCount }, Defer,
             CState = #client_msstate { cur_file_cache_ets = CurFileCacheEts,
                                        dedup_cache_ets = DedupCacheEts }) ->
    case ets:lookup(CurFileCacheEts, MsgId) of
        [] ->
            Defer(); %% may have rolled over
        [{MsgId, Msg, _CacheRefCount}] ->
            ok = maybe_insert_into_cache(DedupCacheEts, RefCount, MsgId, Msg),
            {{ok, Msg}, CState}
    end;
client_read2(_Server, true, _Right, _MsgLocation, Defer, _CState) ->
    %% Of course, in the mean time, the GC could have run and our msg
    %% is actually in a different file, unlocked. However, defering is
    %% the safest and simplest thing to do.
    Defer();
client_read2(Server, false, _Right,
             #msg_location { msg_id = MsgId, ref_count = RefCount, file = File },
             Defer, CState =
                 #client_msstate { file_handles_ets = FileHandlesEts,
                                   file_summary_ets = FileSummaryEts,
                                   dedup_cache_ets  = DedupCacheEts }) ->
    %% It's entirely possible that everything we're doing from here on
    %% is for the wrong file, or a non-existent file, as a GC may have
    %% finished.
    try ets:update_counter(FileSummaryEts, File, {#file_summary.readers, +1})
    catch error:badarg -> %% the File has been GC'd and deleted. Go around.
            read(Server, MsgId, CState)
    end,
    Release = fun() -> ets:update_counter(FileSummaryEts, File,
                                          {#file_summary.readers, -1})
              end,
    %% If a GC hasn't already started, it won't start now. Need to
    %% check again to see if we've been locked in the meantime,
    %% between lookup and update_counter (thus GC started before our
    %% +1).
    [#file_summary { locked = Locked }] =
        ets:lookup(FileSummaryEts, File),
    case Locked of
        true ->
            %% If we get a badarg here, then the GC has finished and
            %% deleted our file. Try going around again. Otherwise,
            %% just defer.

            %% badarg scenario:
            %% we lookup, msg_store locks, gc starts, gc ends, we +1
            %% readers, msg_store ets:deletes (and unlocks the dest)
            try Release(),
                Defer()
            catch error:badarg -> read(Server, MsgId, CState)
            end;
        false ->
            %% Ok, we're definitely safe to continue - a GC can't
            %% start up now, and isn't running, so nothing will tell
            %% us from now on to close the handle if it's already
            %% open. (Well, a GC could start, and could put close
            %% entries into the ets table, but the GC will wait until
            %% we're done here before doing any real work.)

            %% Finally, we need to recheck that the msg is still at
            %% the same place - it's possible an entire GC ran between
            %% us doing the lookup and the +1 on the readers. (Same as
            %% badarg scenario above, but we don't have a missing file
            %% - we just have the /wrong/ file).

            case index_lookup(MsgId, CState) of
                MsgLocation = #msg_location { file = File } ->
                    %% Still the same file.
                    %% This is fine to fail (already exists)
                    ets:insert_new(FileHandlesEts, {{self(), File}, open}),
                    CState1 = close_all_indicated(CState),
                    {Msg, CState2} =
                        read_from_disk(MsgLocation, CState1, DedupCacheEts),
                    ok = maybe_insert_into_cache(DedupCacheEts, RefCount, MsgId,
                                                 Msg),
                    Release(), %% this MUST NOT fail with badarg
                    {{ok, Msg}, CState2};
                MsgLocation -> %% different file!
                    Release(), %% this MUST NOT fail with badarg
                    client_read1(Server, MsgLocation, Defer, CState)
            end
    end.

close_all_indicated(#client_msstate { file_handles_ets = FileHandlesEts } =
                        CState) ->
    Objs = ets:match_object(FileHandlesEts, {{self(), '_'}, close}),
    lists:foldl(fun ({Key = {_Self, File}, close}, CStateM) ->
                        true = ets:delete(FileHandlesEts, Key),
                        close_handle(File, CStateM)
                end, CState, Objs).

%%----------------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------------

init([Server, BaseDir, MsgRefDeltaGen, MsgRefDeltaGenInit]) ->
    process_flag(trap_exit, true),

    ok = file_handle_cache:register_callback(?MODULE, set_maximum_since_use,
                                             [self()]),

    Dir = filename:join(BaseDir, atom_to_list(Server)),
    ok = filelib:ensure_dir(filename:join(Dir, "nothing")),

    {ok, IndexModule} = application:get_env(msg_store_index_module),
    rabbit_log:info("Using ~p to provide index for message store~n",
                    [IndexModule]),
    IndexState = IndexModule:init(Dir),

    InitFile = 0,
    FileSummaryEts = ets:new(rabbit_msg_store_file_summary,
                             [ordered_set, public,
                              {keypos, #file_summary.file}]),
    DedupCacheEts = ets:new(rabbit_msg_store_dedup_cache, [set, public]),
    FileHandlesEts = ets:new(rabbit_msg_store_shared_file_handles,
                             [ordered_set, public]),
    CurFileCacheEts = ets:new(rabbit_msg_store_cur_file, [set, public]),

    State = #msstate { dir                    = Dir,
                       index_module           = IndexModule,
                       index_state            = IndexState,
                       current_file           = InitFile,
                       current_file_handle    = undefined,
                       file_handle_cache      = dict:new(),
                       on_sync                = [],
                       sync_timer_ref         = undefined,
                       sum_valid_data         = 0,
                       sum_file_size          = 0,
                       pending_gc_completion  = [],
                       gc_active              = false,
                       gc_pid                 = undefined,
                       file_handles_ets       = FileHandlesEts,
                       file_summary_ets       = FileSummaryEts,
                       dedup_cache_ets        = DedupCacheEts,
                       cur_file_cache_ets     = CurFileCacheEts
                     },

    ok = count_msg_refs(MsgRefDeltaGen, MsgRefDeltaGenInit, State),
    FileNames =
        sort_file_names(filelib:wildcard("*" ++ ?FILE_EXTENSION, Dir)),
    TmpFileNames =
        sort_file_names(filelib:wildcard("*" ++ ?FILE_EXTENSION_TMP, Dir)),
    ok = recover_crashed_compactions(Dir, FileNames, TmpFileNames),
    %% There should be no more tmp files now, so go ahead and load the
    %% whole lot
    Files = [filename_to_num(FileName) || FileName <- FileNames],
    {Offset, State1 = #msstate { current_file = CurFile }} =
        build_index(Files, State),

    %% read is only needed so that we can seek
    {ok, FileHdl} = rabbit_msg_store_misc:open_file(
                      Dir, rabbit_msg_store_misc:filenum_to_name(CurFile),
                      [read | ?WRITE_MODE]),
    {ok, Offset} = file_handle_cache:position(FileHdl, Offset),
    ok = file_handle_cache:truncate(FileHdl),

    {ok, GCPid} = rabbit_msg_store_gc:start_link(Dir, IndexState, IndexModule,
                                                 FileSummaryEts),

    {ok, State1 #msstate { current_file_handle = FileHdl,
                           gc_pid = GCPid }, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

handle_call({read, MsgId}, From, State) ->
    State1 = read_message(MsgId, From, State),
    noreply(State1);

handle_call({contains, MsgId}, From, State) ->
    State1 = contains_message(MsgId, From, State),
    noreply(State1);

handle_call(new_client_state, _From,
            State = #msstate { index_state        = IndexState, dir = Dir,
                               index_module       = IndexModule,
                               file_handles_ets   = FileHandlesEts,
                               file_summary_ets   = FileSummaryEts,
                               dedup_cache_ets    = DedupCacheEts,
                               cur_file_cache_ets = CurFileCacheEts }) ->
    reply({IndexState, IndexModule, Dir, FileHandlesEts, FileSummaryEts,
           DedupCacheEts, CurFileCacheEts}, State).

handle_cast({write, MsgId, Msg},
            State = #msstate { current_file_handle = CurHdl,
                               current_file        = CurFile,
                               sum_valid_data      = SumValid,
                               sum_file_size       = SumFileSize,
                               file_summary_ets    = FileSummaryEts,
                               cur_file_cache_ets  = CurFileCacheEts }) ->
    true = 0 =< ets:update_counter(CurFileCacheEts, MsgId, {3, -1}),
    case index_lookup(MsgId, State) of
        not_found ->
            %% New message, lots to do
            {ok, CurOffset} = file_handle_cache:current_virtual_offset(CurHdl),
            {ok, TotalSize} = rabbit_msg_file:append(CurHdl, MsgId, Msg),
            ok = index_insert(#msg_location {
                                msg_id = MsgId, ref_count = 1, file = CurFile,
                                offset = CurOffset, total_size = TotalSize },
                              State),
            [#file_summary { valid_total_size = ValidTotalSize,
                             contiguous_top = ContiguousTop,
                             right = undefined,
                             locked = false,
                             file_size = FileSize }] =
                ets:lookup(FileSummaryEts, CurFile),
            ValidTotalSize1 = ValidTotalSize + TotalSize,
            ContiguousTop1 = if CurOffset =:= ContiguousTop ->
                                     %% can't be any holes in this file
                                     ValidTotalSize1;
                                true -> ContiguousTop
                             end,
            true = ets:update_element(
                     FileSummaryEts,
                     CurFile,
                     [{#file_summary.valid_total_size, ValidTotalSize1},
                      {#file_summary.contiguous_top, ContiguousTop1},
                      {#file_summary.file_size, FileSize + TotalSize}]),
            NextOffset = CurOffset + TotalSize,
            noreply(maybe_compact(maybe_roll_to_new_file(
                                    NextOffset, State #msstate
                                    { sum_valid_data = SumValid + TotalSize,
                                      sum_file_size = SumFileSize + TotalSize }
                                   )));
        #msg_location { ref_count = RefCount } ->
            %% We already know about it, just update counter. Only
            %% update field otherwise bad interaction with concurrent GC
            ok = index_update_fields(MsgId,
                                     {#msg_location.ref_count, RefCount + 1},
                                     State),
            noreply(State)
    end;

handle_cast({remove, MsgIds}, State) ->
    State1 = lists:foldl(
               fun (MsgId, State2) -> remove_message(MsgId, State2) end,
               State, MsgIds),
    noreply(maybe_compact(State1));

handle_cast({release, MsgIds}, State =
                #msstate { dedup_cache_ets = DedupCacheEts }) ->
    lists:foreach(
      fun (MsgId) -> decrement_cache(DedupCacheEts, MsgId) end, MsgIds),
    noreply(State);

handle_cast({sync, MsgIds, K},
            State = #msstate { current_file        = CurFile,
                               current_file_handle = CurHdl,
                               on_sync             = Syncs }) ->
    {ok, SyncOffset} = file_handle_cache:last_sync_offset(CurHdl),
    case lists:any(fun (MsgId) ->
                           #msg_location { file = File, offset = Offset } =
                               index_lookup(MsgId, State),
                           File =:= CurFile andalso Offset >= SyncOffset
                   end, MsgIds) of
        false -> K(),
                 noreply(State);
        true  -> noreply(State #msstate { on_sync = [K | Syncs] })
    end;

handle_cast(sync, State) ->
    noreply(internal_sync(State));

handle_cast({gc_done, Reclaimed, Source, Dest},
            State = #msstate { sum_file_size = SumFileSize,
                               gc_active = {Source, Dest},
                               file_handles_ets = FileHandlesEts,
                               file_summary_ets = FileSummaryEts }) ->
    %% GC done, so now ensure that any clients that have open fhs to
    %% those files close them before using them again. This has to be
    %% done here, and not when starting up the GC, because if done
    %% when starting up the GC, the client could find the close, and
    %% close and reopen the fh, whilst the GC is waiting for readers
    %% to disappear, before it's actually done the GC.
    true = mark_handle_to_close(FileHandlesEts, Source),
    true = mark_handle_to_close(FileHandlesEts, Dest),
    %% we always move data left, so Source has gone and was on the
    %% right, so need to make dest = source.right.left, and also
    %% dest.right = source.right
    [#file_summary { left = Dest, right = SourceRight, locked = true,
                     readers = 0 }] =
        ets:lookup(FileSummaryEts, Source),
    %% this could fail if SourceRight == undefined
    ets:update_element(FileSummaryEts, SourceRight,
                       {#file_summary.left, Dest}),
    true = ets:update_element(FileSummaryEts, Dest,
                              [{#file_summary.locked, false},
                               {#file_summary.right, SourceRight}]),
    true = ets:delete(FileSummaryEts, Source),
    noreply(run_pending(
              State #msstate { sum_file_size = SumFileSize - Reclaimed,
                               gc_active = false }));

handle_cast({set_maximum_since_use, Age}, State) ->
    ok = file_handle_cache:set_maximum_since_use(Age),
    noreply(State).

handle_info(timeout, State) ->
    noreply(internal_sync(State));

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State}.

terminate(_Reason, State = #msstate { index_state         = IndexState,
                                      index_module        = IndexModule,
                                      current_file_handle = FileHdl,
                                      gc_pid              = GCPid,
                                      file_handles_ets    = FileHandlesEts,
                                      file_summary_ets    = FileSummaryEts,
                                      dedup_cache_ets     = DedupCacheEts,
                                      cur_file_cache_ets  = CurFileCacheEts }) ->
    %% stop the gc first, otherwise it could be working and we pull
    %% out the ets tables from under it.
    ok = rabbit_msg_store_gc:stop(GCPid),
    State1 = case FileHdl of
                 undefined -> State;
                 _ -> State2 = internal_sync(State),
                      file_handle_cache:close(FileHdl),
                      State2
             end,
    State3 = close_all_handles(State1),
    ets:delete(FileSummaryEts),
    ets:delete(DedupCacheEts),
    ets:delete(FileHandlesEts),
    ets:delete(CurFileCacheEts),
    IndexModule:terminate(IndexState),
    State3 #msstate { index_state         = undefined,
                      current_file_handle = undefined }.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_pre_hibernate(State) ->
    {hibernate, maybe_compact(State)}.

%%----------------------------------------------------------------------------
%% general helper functions
%%----------------------------------------------------------------------------

noreply(State) ->
    {State1, Timeout} = next_state(State),
    {noreply, State1, Timeout}.

reply(Reply, State) ->
    {State1, Timeout} = next_state(State),
    {reply, Reply, State1, Timeout}.

next_state(State = #msstate { on_sync = [], sync_timer_ref = undefined }) ->
    {State, hibernate};
next_state(State = #msstate { sync_timer_ref = undefined }) ->
    {start_sync_timer(State), 0};
next_state(State = #msstate { on_sync = [] }) ->
    {stop_sync_timer(State), hibernate};
next_state(State) ->
    {State, 0}.

start_sync_timer(State = #msstate { sync_timer_ref = undefined }) ->
    {ok, TRef} = timer:apply_after(?SYNC_INTERVAL, ?MODULE, sync, []),
    State #msstate { sync_timer_ref = TRef }.

stop_sync_timer(State = #msstate { sync_timer_ref = undefined }) ->
    State;
stop_sync_timer(State = #msstate { sync_timer_ref = TRef }) ->
    {ok, cancel} = timer:cancel(TRef),
    State #msstate { sync_timer_ref = undefined }.

filename_to_num(FileName) -> list_to_integer(filename:rootname(FileName)).

sort_file_names(FileNames) ->
    lists:sort(fun (A, B) -> filename_to_num(A) < filename_to_num(B) end,
               FileNames).

internal_sync(State = #msstate { current_file_handle = CurHdl,
                        on_sync = Syncs }) ->
    State1 = stop_sync_timer(State),
    case Syncs of
        [] -> State1;
        _ ->
            ok = file_handle_cache:sync(CurHdl),
            lists:foreach(fun (K) -> K() end, lists:reverse(Syncs)),
            State1 #msstate { on_sync = [] }
    end.

read_message(MsgId, From, State =
                 #msstate { dedup_cache_ets = DedupCacheEts }) ->
    case index_lookup(MsgId, State) of
        not_found -> gen_server2:reply(From, not_found),
                     State;
        MsgLocation ->
            case fetch_and_increment_cache(DedupCacheEts, MsgId) of
                not_found ->
                    read_message1(From, MsgLocation, State);
                Msg ->
                    gen_server2:reply(From, {ok, Msg}),
                    State
            end
    end.

read_message1(From, #msg_location { msg_id = MsgId, ref_count = RefCount,
                                    file = File, offset = Offset } = MsgLoc,
              State = #msstate { current_file = CurFile,
                                 current_file_handle = CurHdl,
                                 file_summary_ets = FileSummaryEts,
                                 dedup_cache_ets = DedupCacheEts,
                                 cur_file_cache_ets = CurFileCacheEts }) ->
    case File =:= CurFile of
        true ->
            {Msg, State1} =
                %% can return [] if msg in file existed on startup
                case ets:lookup(CurFileCacheEts, MsgId) of
                    [] ->
                        ok = case {ok, Offset} >=
                                 file_handle_cache:current_raw_offset(CurHdl) of
                                 true  -> file_handle_cache:flush(CurHdl);
                                 false -> ok
                             end,
                        read_from_disk(MsgLoc, State, DedupCacheEts);
                    [{MsgId, Msg1, _CacheRefCount}] ->
                        {Msg1, State}
                end,
            ok = maybe_insert_into_cache(DedupCacheEts, RefCount, MsgId, Msg),
            gen_server2:reply(From, {ok, Msg}),
            State1;
        false ->
            [#file_summary { locked = Locked }] =
                ets:lookup(FileSummaryEts, File),
            case Locked of
                true ->
                    add_to_pending_gc_completion({read, MsgId, From}, State);
                false ->
                    {Msg, State1} = read_from_disk(MsgLoc, State, DedupCacheEts),
                    gen_server2:reply(From, {ok, Msg}),
                    State1
            end
    end.

read_from_disk(#msg_location { msg_id = MsgId, ref_count = RefCount,
                               file = File, offset = Offset,
                               total_size = TotalSize }, State,
               DedupCacheEts) ->
    {Hdl, State1} = get_read_handle(File, State),
    {ok, Offset} = file_handle_cache:position(Hdl, Offset),
    {ok, {MsgId, Msg}} =
        case rabbit_msg_file:read(Hdl, TotalSize) of
            {ok, {MsgId, _}} = Obj ->
                Obj;
            Rest ->
                throw({error, {misread, [{old_state, State},
                                         {file_num,  File},
                                         {offset,    Offset},
                                         {msg_id,    MsgId},
                                         {read,      Rest},
                                         {proc_dict, get()}
                                        ]}})
        end,
    ok = maybe_insert_into_cache(DedupCacheEts, RefCount, MsgId, Msg),
    {Msg, State1}.

maybe_insert_into_cache(DedupCacheEts, RefCount, MsgId, Msg)
  when RefCount > 1 ->
    insert_into_cache(DedupCacheEts, MsgId, Msg);
maybe_insert_into_cache(_DedupCacheEts, _RefCount, _MsgId, _Msg) ->
    ok.

contains_message(MsgId, From, State = #msstate { gc_active = GCActive }) ->
    case index_lookup(MsgId, State) of
        not_found ->
            gen_server2:reply(From, false),
            State;
        #msg_location { file = File } ->
            case GCActive of
                {A, B} when File == A orelse File == B ->
                    add_to_pending_gc_completion(
                      {contains, MsgId, From}, State);
                _ ->
                    gen_server2:reply(From, true),
                    State
            end
    end.

remove_message(MsgId, State = #msstate { sum_valid_data = SumValid,
                                         file_summary_ets = FileSummaryEts,
                                         dedup_cache_ets = DedupCacheEts }) ->
    #msg_location { ref_count = RefCount, file = File,
                    offset = Offset, total_size = TotalSize } =
        index_lookup(MsgId, State),
    case RefCount of
        1 ->
            %% don't remove from CUR_FILE_CACHE_ETS_NAME here because
            %% there may be further writes in the mailbox for the same
            %% msg.
            ok = remove_cache_entry(DedupCacheEts, MsgId),
            [#file_summary { valid_total_size = ValidTotalSize,
                             contiguous_top = ContiguousTop,
                             locked = Locked }] =
                ets:lookup(FileSummaryEts, File),
            case Locked of
                true ->
                    add_to_pending_gc_completion({remove, MsgId}, State);
                false ->
                    ok = index_delete(MsgId, State),
                    ContiguousTop1 = lists:min([ContiguousTop, Offset]),
                    ValidTotalSize1 = ValidTotalSize - TotalSize,
                    true = ets:update_element(
                             FileSummaryEts, File,
                             [{#file_summary.valid_total_size, ValidTotalSize1},
                              {#file_summary.contiguous_top, ContiguousTop1}]),
                    State1 = delete_file_if_empty(File, State),
                    State1 #msstate { sum_valid_data = SumValid - TotalSize }
            end;
        _ when 1 < RefCount ->
            ok = decrement_cache(DedupCacheEts, MsgId),
            %% only update field, otherwise bad interaction with concurrent GC
            ok = index_update_fields(MsgId,
                                     {#msg_location.ref_count, RefCount - 1},
                                     State),
            State
    end.

add_to_pending_gc_completion(
  Op, State = #msstate { pending_gc_completion = Pending }) ->
    State #msstate { pending_gc_completion = [Op | Pending] }.

run_pending(State = #msstate { pending_gc_completion = [] }) ->
    State;
run_pending(State = #msstate { pending_gc_completion = Pending }) ->
    State1 = State #msstate { pending_gc_completion = [] },
    lists:foldl(fun run_pending/2, State1, lists:reverse(Pending)).

run_pending({read, MsgId, From}, State) ->
    read_message(MsgId, From, State);
run_pending({contains, MsgId, From}, State) ->
    contains_message(MsgId, From, State);
run_pending({remove, MsgId}, State) ->
    remove_message(MsgId, State).

close_handle(Key, CState = #client_msstate { file_handle_cache = FHC }) ->
    CState #client_msstate { file_handle_cache = close_handle(Key, FHC) };

close_handle(Key, State = #msstate { file_handle_cache = FHC }) ->
    State #msstate { file_handle_cache = close_handle(Key, FHC) };

close_handle(Key, FHC) ->
    case dict:find(Key, FHC) of
        {ok, Hdl} ->
            ok = file_handle_cache:close(Hdl),
            dict:erase(Key, FHC);
        error -> FHC
    end.

close_all_handles(CState = #client_msstate { file_handles_ets = FileHandlesEts,
                                             file_handle_cache = FHC }) ->
    Self = self(),
    ok = dict:fold(fun (File, Hdl, ok) ->
                           true =
                               ets:delete(FileHandlesEts, {Self, File}),
                           file_handle_cache:close(Hdl)
                   end, ok, FHC),
    CState #client_msstate { file_handle_cache = dict:new() };

close_all_handles(State = #msstate { file_handle_cache = FHC }) ->
    ok = dict:fold(fun (_Key, Hdl, ok) ->
                           file_handle_cache:close(Hdl)
                   end, ok, FHC),
    State #msstate { file_handle_cache = dict:new() }.

get_read_handle(FileNum, CState = #client_msstate { file_handle_cache = FHC,
                                                   dir = Dir }) ->
    {Hdl, FHC2} = get_read_handle(FileNum, FHC, Dir),
    {Hdl, CState #client_msstate { file_handle_cache = FHC2 }};

get_read_handle(FileNum, State = #msstate { file_handle_cache = FHC,
                                            dir = Dir }) ->
    {Hdl, FHC2} = get_read_handle(FileNum, FHC, Dir),
    {Hdl, State #msstate { file_handle_cache = FHC2 }}.

get_read_handle(FileNum, FHC, Dir) ->
    case dict:find(FileNum, FHC) of
        {ok, Hdl} ->
            {Hdl, FHC};
        error ->
            {ok, Hdl} = rabbit_msg_store_misc:open_file(
                          Dir, rabbit_msg_store_misc:filenum_to_name(FileNum),
                          ?READ_MODE),
            {Hdl, dict:store(FileNum, Hdl, FHC) }
    end.

%%----------------------------------------------------------------------------
%% message cache helper functions
%%----------------------------------------------------------------------------

remove_cache_entry(DedupCacheEts, MsgId) ->
    true = ets:delete(DedupCacheEts, MsgId),
    ok.

fetch_and_increment_cache(DedupCacheEts, MsgId) ->
    case ets:lookup(DedupCacheEts, MsgId) of
        [] ->
            not_found;
        [{_MsgId, Msg, _RefCount}] ->
            try
                ets:update_counter(DedupCacheEts, MsgId, {3, 1})
            catch error:badarg ->
                    %% someone has deleted us in the meantime, insert us
                    ok = insert_into_cache(DedupCacheEts, MsgId, Msg)
            end,
            Msg
    end.

decrement_cache(DedupCacheEts, MsgId) ->
    true = try case ets:update_counter(DedupCacheEts, MsgId, {3, -1}) of
                   N when N =< 0 -> true = ets:delete(DedupCacheEts, MsgId);
                   _N            -> true
               end
           catch error:badarg ->
                   %% MsgId is not in there because although it's been
                   %% delivered, it's never actually been read (think:
                   %% persistent message held in RAM)
                   true
           end,
    ok.

insert_into_cache(DedupCacheEts, MsgId, Msg) ->
    case ets:insert_new(DedupCacheEts, {MsgId, Msg, 1}) of
        true  -> ok;
        false -> try
                     ets:update_counter(DedupCacheEts, MsgId, {3, 1}),
                     ok
                 catch error:badarg ->
                         insert_into_cache(DedupCacheEts, MsgId, Msg)
                 end
    end.

%%----------------------------------------------------------------------------
%% index
%%----------------------------------------------------------------------------

index_lookup(Key, #client_msstate { index_module = Index, index_state = State }) ->
    Index:lookup(Key, State);

index_lookup(Key, #msstate { index_module = Index, index_state = State }) ->
    Index:lookup(Key, State).

index_insert(Obj, #msstate { index_module = Index, index_state = State }) ->
    Index:insert(Obj, State).

index_update(Obj, #msstate { index_module = Index, index_state = State }) ->
    Index:update(Obj, State).

index_update_fields(Key, Updates,
                    #msstate { index_module = Index, index_state = State }) ->
    Index:update_fields(Key, Updates, State).

index_delete(Key, #msstate { index_module = Index, index_state = State }) ->
    Index:delete(Key, State).

index_delete_by_file(File, #msstate { index_module = Index,
                                      index_state = State }) ->
    Index:delete_by_file(File, State).

%%----------------------------------------------------------------------------
%% recovery
%%----------------------------------------------------------------------------

count_msg_refs(Gen, Seed, State) ->
    case Gen(Seed) of
        finished -> ok;
        {_MsgId, 0, Next} -> count_msg_refs(Gen, Next, State);
        {MsgId, Delta, Next} ->
            ok = case index_lookup(MsgId, State) of
                     not_found ->
                         index_insert(#msg_location { msg_id = MsgId,
                                                      ref_count = Delta },
                                      State);
                     StoreEntry = #msg_location { ref_count = RefCount } ->
                         NewRefCount = RefCount + Delta,
                         case NewRefCount of
                             0 -> index_delete(MsgId, State);
                             _ -> index_update(StoreEntry #msg_location {
                                                 ref_count = NewRefCount },
                                               State)
                         end
                 end,
            count_msg_refs(Gen, Next, State)
    end.

recover_crashed_compactions(Dir, FileNames, TmpFileNames) ->
    lists:foreach(fun (TmpFileName) ->
                          ok = recover_crashed_compactions1(
                                 Dir, FileNames, TmpFileName)
                  end, TmpFileNames),
    ok.

recover_crashed_compactions1(Dir, FileNames, TmpFileName) ->
    NonTmpRelatedFileName = filename:rootname(TmpFileName) ++ ?FILE_EXTENSION,
    true = lists:member(NonTmpRelatedFileName, FileNames),
    {ok, UncorruptedMessagesTmp, MsgIdsTmp} =
        scan_file_for_valid_messages_msg_ids(Dir, TmpFileName),
    {ok, UncorruptedMessages, MsgIds} =
        scan_file_for_valid_messages_msg_ids(Dir, NonTmpRelatedFileName),
    %% 1) It's possible that everything in the tmp file is also in the
    %%    main file such that the main file is (prefix ++
    %%    tmpfile). This means that compaction failed immediately
    %%    prior to the final step of deleting the tmp file. Plan: just
    %%    delete the tmp file
    %% 2) It's possible that everything in the tmp file is also in the
    %%    main file but with holes throughout (or just somthing like
    %%    main = (prefix ++ hole ++ tmpfile)). This means that
    %%    compaction wrote out the tmp file successfully and then
    %%    failed. Plan: just delete the tmp file and allow the
    %%    compaction to eventually be triggered later
    %% 3) It's possible that everything in the tmp file is also in the
    %%    main file but such that the main file does not end with tmp
    %%    file (and there are valid messages in the suffix; main =
    %%    (prefix ++ tmpfile[with extra holes?] ++ suffix)). This
    %%    means that compaction failed as we were writing out the tmp
    %%    file. Plan: just delete the tmp file and allow the
    %%    compaction to eventually be triggered later
    %% 4) It's possible that there are messages in the tmp file which
    %%    are not in the main file. This means that writing out the
    %%    tmp file succeeded, but then we failed as we were copying
    %%    them back over to the main file, after truncating the main
    %%    file. As the main file has already been truncated, it should
    %%    consist only of valid messages. Plan: Truncate the main file
    %%    back to before any of the files in the tmp file and copy
    %%    them over again
    TmpPath = rabbit_msg_store_misc:form_filename(Dir, TmpFileName),
    case is_sublist(MsgIdsTmp, MsgIds) of
        true -> %% we're in case 1, 2 or 3 above. Just delete the tmp file
                %% note this also catches the case when the tmp file
                %% is empty
            ok = file:delete(TmpPath);
        false ->
            %% We're in case 4 above. We only care about the inital
            %% msgs in main file that are not in the tmp file. If
            %% there are no msgs in the tmp file then we would be in
            %% the 'true' branch of this case, so we know the
            %% lists:last call is safe.
            EldestTmpMsgId = lists:last(MsgIdsTmp),
            {MsgIds1, UncorruptedMessages1}
                = case lists:splitwith(
                         fun (MsgId) -> MsgId /= EldestTmpMsgId end, MsgIds) of
                      {_MsgIds, []} -> %% no msgs from tmp in main
                          {MsgIds, UncorruptedMessages};
                      {Dropped, [EldestTmpMsgId | Rest]} ->
                          %% Msgs in Dropped are in tmp, so forget them.
                          %% *cry*. Lists indexed from 1.
                          {Rest, lists:sublist(UncorruptedMessages,
                                               2 + length(Dropped),
                                               length(Rest))}
                  end,
            %% The main file prefix should be contiguous
            {Top, MsgIds1} = find_contiguous_block_prefix(
                               lists:reverse(UncorruptedMessages1)),
            %% we should have that none of the messages in the prefix
            %% are in the tmp file
            true = is_disjoint(MsgIds1, MsgIdsTmp),
            %% must open with read flag, otherwise will stomp over contents
            {ok, MainHdl} = rabbit_msg_store_misc:open_file(
                              Dir, NonTmpRelatedFileName, [read | ?WRITE_MODE]),
            %% Wipe out any rubbish at the end of the file. Remember
            %% the head of the list will be the highest entry in the
            %% file.
            [{_, TmpTopTotalSize, TmpTopOffset}|_] = UncorruptedMessagesTmp,
            TmpSize = TmpTopOffset + TmpTopTotalSize,
            %% Extend the main file as big as necessary in a single
            %% move. If we run out of disk space, this truncate could
            %% fail, but we still aren't risking losing data
            ok = rabbit_msg_store_misc:truncate_and_extend_file(
                   MainHdl, Top, Top + TmpSize),
            {ok, TmpHdl} = rabbit_msg_store_misc:open_file(
                             Dir, TmpFileName, ?READ_AHEAD_MODE),
            {ok, TmpSize} = file_handle_cache:copy(TmpHdl, MainHdl, TmpSize),
            ok = file_handle_cache:close(MainHdl),
            ok = file_handle_cache:delete(TmpHdl),

            {ok, _MainMessages, MsgIdsMain} =
                scan_file_for_valid_messages_msg_ids(
                  Dir, NonTmpRelatedFileName),
            %% check that everything in MsgIds1 is in MsgIdsMain
            true = is_sublist(MsgIds1, MsgIdsMain),
            %% check that everything in MsgIdsTmp is in MsgIdsMain
            true = is_sublist(MsgIdsTmp, MsgIdsMain)
    end,
    ok.

is_sublist(SmallerL, BiggerL) ->
    lists:all(fun (Item) -> lists:member(Item, BiggerL) end, SmallerL).

is_disjoint(SmallerL, BiggerL) ->
    lists:all(fun (Item) -> not lists:member(Item, BiggerL) end, SmallerL).

scan_file_for_valid_messages_msg_ids(Dir, FileName) ->
    {ok, Messages, _FileSize} =
        rabbit_msg_store_misc:scan_file_for_valid_messages(Dir, FileName),
    {ok, Messages, [MsgId || {MsgId, _TotalSize, _FileOffset} <- Messages]}.

%% Takes the list in *ascending* order (i.e. eldest message
%% first). This is the opposite of what scan_file_for_valid_messages
%% produces. The list of msgs that is produced is youngest first.
find_contiguous_block_prefix([]) -> {0, []};
find_contiguous_block_prefix(List) ->
    find_contiguous_block_prefix(List, 0, []).

find_contiguous_block_prefix([], ExpectedOffset, MsgIds) ->
    {ExpectedOffset, MsgIds};
find_contiguous_block_prefix([{MsgId, TotalSize, ExpectedOffset} | Tail],
                             ExpectedOffset, MsgIds) ->
    ExpectedOffset1 = ExpectedOffset + TotalSize,
    find_contiguous_block_prefix(Tail, ExpectedOffset1, [MsgId | MsgIds]);
find_contiguous_block_prefix([_MsgAfterGap | _Tail], ExpectedOffset, MsgIds) ->
    {ExpectedOffset, MsgIds}.

build_index([], State) ->
    build_index(undefined, [State #msstate.current_file], State);
build_index(Files, State) ->
    {Offset, State1} = build_index(undefined, Files, State),
    {Offset, lists:foldl(fun delete_file_if_empty/2, State1, Files)}.

build_index(Left, [], State = #msstate { file_summary_ets = FileSummaryEts }) ->
    ok = index_delete_by_file(undefined, State),
    Offset = case ets:lookup(FileSummaryEts, Left) of
                 []                                       -> 0;
                 [#file_summary { file_size = FileSize }] -> FileSize
             end,
    {Offset, State #msstate { current_file = Left }};
build_index(Left, [File|Files],
            State = #msstate { dir = Dir, sum_valid_data = SumValid,
                               sum_file_size = SumFileSize,
                               file_summary_ets = FileSummaryEts }) ->
    {ok, Messages, FileSize} =
        rabbit_msg_store_misc:scan_file_for_valid_messages(
          Dir, rabbit_msg_store_misc:filenum_to_name(File)),
    {ValidMessages, ValidTotalSize} =
        lists:foldl(
          fun (Obj = {MsgId, TotalSize, Offset}, {VMAcc, VTSAcc}) ->
                  case index_lookup(MsgId, State) of
                      not_found -> {VMAcc, VTSAcc};
                      StoreEntry ->
                          ok = index_update(StoreEntry #msg_location {
                                              file = File, offset = Offset,
                                              total_size = TotalSize },
                                            State),
                          {[Obj | VMAcc], VTSAcc + TotalSize}
                  end
          end, {[], 0}, Messages),
    %% foldl reverses lists, find_contiguous_block_prefix needs
    %% msgs eldest first, so, ValidMessages is the right way round
    {ContiguousTop, _} = find_contiguous_block_prefix(ValidMessages),
    {Right, FileSize1} =
        case Files of
            %% if it's the last file, we'll truncate to remove any
            %% rubbish above the last valid message. This affects the
            %% file size.
            []    -> {undefined, case ValidMessages of
                                     [] -> 0;
                                     _  -> {_MsgId, TotalSize, Offset} =
                                               lists:last(ValidMessages),
                                           Offset + TotalSize
                                 end};
            [F|_] -> {F, FileSize}
        end,
    true =
        ets:insert_new(FileSummaryEts, #file_summary {
                          file = File, valid_total_size = ValidTotalSize,
                          contiguous_top = ContiguousTop, locked = false,
                          left = Left, right = Right, file_size = FileSize1,
                          readers = 0 }),
    build_index(File, Files,
                State #msstate { sum_valid_data = SumValid + ValidTotalSize,
                                 sum_file_size = SumFileSize + FileSize1 }).

%%----------------------------------------------------------------------------
%% garbage collection / compaction / aggregation
%%----------------------------------------------------------------------------

maybe_roll_to_new_file(Offset,
                       State = #msstate { dir                 = Dir,
                                          current_file_handle = CurHdl,
                                          current_file        = CurFile,
                                          file_summary_ets    = FileSummaryEts,
                                          cur_file_cache_ets  = CurFileCacheEts })
  when Offset >= ?FILE_SIZE_LIMIT ->
    State1 = internal_sync(State),
    ok = file_handle_cache:close(CurHdl),
    NextFile = CurFile + 1,
    {ok, NextHdl} = rabbit_msg_store_misc:open_file(
                      Dir, rabbit_msg_store_misc:filenum_to_name(NextFile),
                      ?WRITE_MODE),
    true = ets:insert_new(
             FileSummaryEts, #file_summary {
                file = NextFile, valid_total_size = 0, contiguous_top = 0,
                left = CurFile, right = undefined, file_size = 0,
                locked = false, readers = 0 }),
    true = ets:update_element(FileSummaryEts, CurFile,
                              {#file_summary.right, NextFile}),
    true = ets:match_delete(CurFileCacheEts, {'_', '_', 0}),
    State1 #msstate { current_file_handle = NextHdl,
                      current_file        = NextFile };
maybe_roll_to_new_file(_, State) ->
    State.

maybe_compact(State = #msstate { sum_valid_data   = SumValid,
                                 sum_file_size    = SumFileSize,
                                 gc_active        = false,
                                 gc_pid           = GCPid,
                                 file_summary_ets = FileSummaryEts })
  when (SumFileSize - SumValid) / SumFileSize > ?GARBAGE_FRACTION ->
    First = ets:first(FileSummaryEts),
    N = random_distributions:geometric(?GEOMETRIC_P),
    case find_files_to_gc(FileSummaryEts, N, First) of
        undefined ->
            State;
        {Source, Dest} ->
            State1 = close_handle(Source, close_handle(Dest, State)),
            true = ets:update_element(FileSummaryEts, Source,
                                      {#file_summary.locked, true}),
            true = ets:update_element(FileSummaryEts, Dest,
                                      {#file_summary.locked, true}),
            ok = rabbit_msg_store_gc:gc(GCPid, Source, Dest),
            State1 #msstate { gc_active = {Source, Dest} }
    end;
maybe_compact(State) ->
    State.

mark_handle_to_close(FileHandlesEts, File) ->
    [ ets:update_element(FileHandlesEts, Key, {2, close})
      || {Key, open} <- ets:match_object(FileHandlesEts,
                                         {{'_', File}, open}) ],
    true.

find_files_to_gc(_FileSummaryEts, _N, '$end_of_table') ->
    undefined;
find_files_to_gc(FileSummaryEts, N, First) ->
    [FirstObj = #file_summary { right = Right }] =
        ets:lookup(FileSummaryEts, First),
    Pairs = find_files_to_gc(FileSummaryEts, N, FirstObj,
                             ets:lookup(FileSummaryEts, Right), []),
    case Pairs of
        []     -> undefined;
        [Pair] -> Pair;
        _      -> M = 1 + (N rem length(Pairs)),
                  lists:nth(M, Pairs)
    end.

find_files_to_gc(_FileSummaryEts, _N, #file_summary {}, [], Pairs) ->
    lists:reverse(Pairs);
find_files_to_gc(FileSummaryEts, N,
                 #file_summary { right = Source, file = Dest,
                                 valid_total_size = DestValid },
                 [SourceObj = #file_summary { left = Dest, right = SourceRight,
                                              valid_total_size = SourceValid,
                                              file = Source }],
                 Pairs) when DestValid + SourceValid =< ?FILE_SIZE_LIMIT andalso
                             not is_atom(SourceRight) ->
    Pair = {Source, Dest},
    case N == 1 of
        true  -> [Pair];
        false -> find_files_to_gc(FileSummaryEts, (N - 1), SourceObj,
                                  ets:lookup(FileSummaryEts, SourceRight),
                                  [Pair | Pairs])
    end;
find_files_to_gc(FileSummaryEts, N, _Left,
                 [Right = #file_summary { right = RightRight }], Pairs) ->
    find_files_to_gc(
      FileSummaryEts, N, Right, ets:lookup(FileSummaryEts, RightRight), Pairs).

delete_file_if_empty(File, State = #msstate { current_file = File }) ->
    State;
delete_file_if_empty(File, State =
                         #msstate { dir = Dir, sum_file_size = SumFileSize,
                                    file_handles_ets = FileHandlesEts,
                                    file_summary_ets = FileSummaryEts }) ->
    [#file_summary { valid_total_size = ValidData, file_size = FileSize,
                     left = Left, right = Right, locked = false }]
        = ets:lookup(FileSummaryEts, File),
    case ValidData of
        %% we should NEVER find the current file in here hence right
        %% should always be a file, not undefined
        0 -> case {Left, Right} of
                 {undefined, _} when not is_atom(Right) ->
                     %% the eldest file is empty.
                     true = ets:update_element(
                              FileSummaryEts, Right,
                              {#file_summary.left, undefined});
                 {_, _} when not is_atom(Right) ->
                     true = ets:update_element(FileSummaryEts, Right,
                                               {#file_summary.left, Left}),
                     true = ets:update_element(FileSummaryEts, Left,
                                               {#file_summary.right, Right})
             end,
             true = mark_handle_to_close(FileHandlesEts, File),
             true = ets:delete(FileSummaryEts, File),
             State1 = close_handle(File, State),
             ok = file:delete(rabbit_msg_store_misc:form_filename(
                                Dir,
                                rabbit_msg_store_misc:filenum_to_name(File))),
             State1 #msstate { sum_file_size = SumFileSize - FileSize };
        _ -> State
    end.