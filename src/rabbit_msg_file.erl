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

-module(rabbit_msg_file).

-export([append/3, read/2, scan/1]).

%%----------------------------------------------------------------------------

-define(INTEGER_SIZE_BYTES,      8).
-define(INTEGER_SIZE_BITS,       (8 * ?INTEGER_SIZE_BYTES)).
-define(WRITE_OK_SIZE_BITS,      8).
-define(WRITE_OK_MARKER,         255).
-define(FILE_PACKING_ADJUSTMENT, (1 + ?INTEGER_SIZE_BYTES)).
-define(GUID_SIZE_BYTES,         16).
-define(GUID_SIZE_BITS,          (8 * ?GUID_SIZE_BYTES)).
-define(SIZE_AND_GUID_BYTES,     (?GUID_SIZE_BYTES + ?INTEGER_SIZE_BYTES)).

%%----------------------------------------------------------------------------

-include("rabbit_msg_store.hrl").

-ifdef(use_specs).

-type(position() :: non_neg_integer()).
-type(msg_size() :: non_neg_integer()).

-spec(append/3 :: (io_device(), guid(), msg()) ->
             ({'ok', msg_size()} | {'error', any()})).
-spec(read/2 :: (io_device(), msg_size()) ->
             ({'ok', {guid(), msg()}} | {'error', any()})).
-spec(scan/1 :: (io_device()) ->
             {'ok', [{guid(), msg_size(), position()}], position()}).

-endif.

%%----------------------------------------------------------------------------

append(FileHdl, Guid, MsgBody)
  when is_binary(Guid) andalso size(Guid) =< ?GUID_SIZE_BYTES ->
    MsgBodyBin  = term_to_binary(MsgBody),
    MsgBodyBinSize = size(MsgBodyBin),
    Size = MsgBodyBinSize + ?GUID_SIZE_BYTES,
    case file_handle_cache:append(FileHdl,
                                  <<Size:?INTEGER_SIZE_BITS,
                                   Guid:?GUID_SIZE_BYTES/binary,
                                   MsgBodyBin:MsgBodyBinSize/binary,
                                   ?WRITE_OK_MARKER:?WRITE_OK_SIZE_BITS>>) of
        ok -> {ok, Size + ?FILE_PACKING_ADJUSTMENT};
        KO -> KO
    end.

read(FileHdl, TotalSize) ->
    Size = TotalSize - ?FILE_PACKING_ADJUSTMENT,
    BodyBinSize = Size - ?GUID_SIZE_BYTES,
    case file_handle_cache:read(FileHdl, TotalSize) of
        {ok, <<Size:?INTEGER_SIZE_BITS,
               Guid:?GUID_SIZE_BYTES/binary,
               MsgBodyBin:BodyBinSize/binary,
               ?WRITE_OK_MARKER:?WRITE_OK_SIZE_BITS>>} ->
            {ok, {Guid, binary_to_term(MsgBodyBin)}};
        KO -> KO
    end.

scan(FileHdl) -> scan(FileHdl, 0, []).

scan(FileHdl, Offset, Acc) ->
    case read_next(FileHdl, Offset) of
        eof -> {ok, Acc, Offset};
        {corrupted, NextOffset} ->
            scan(FileHdl, NextOffset, Acc);
        {ok, {Guid, TotalSize, NextOffset}} ->
            scan(FileHdl, NextOffset, [{Guid, TotalSize, Offset} | Acc]);
        _KO ->
            %% bad message, but we may still have recovered some valid messages
            {ok, Acc, Offset}
    end.

read_next(FileHdl, Offset) ->
    case file_handle_cache:read(FileHdl, ?SIZE_AND_GUID_BYTES) of
        %% Here we take option 5 from
        %% http://www.erlang.org/cgi-bin/ezmlm-cgi?2:mss:1569 in which
        %% we read the Guid as a number, and then convert it back to
        %% a binary in order to work around bugs in Erlang's GC.
        {ok, <<Size:?INTEGER_SIZE_BITS, GuidNum:?GUID_SIZE_BITS>>} ->
            case Size of
                0 -> eof; %% Nothing we can do other than stop
                _ ->
                    TotalSize = Size + ?FILE_PACKING_ADJUSTMENT,
                    ExpectedAbsPos = Offset + TotalSize - 1,
                    case file_handle_cache:position(
                           FileHdl, {cur, Size - ?GUID_SIZE_BYTES}) of
                        {ok, ExpectedAbsPos} ->
                            NextOffset = ExpectedAbsPos + 1,
                            case file_handle_cache:read(FileHdl, 1) of
                                {ok,
                                 <<?WRITE_OK_MARKER: ?WRITE_OK_SIZE_BITS>>} ->
                                    <<Guid:?GUID_SIZE_BYTES/binary>> =
                                        <<GuidNum:?GUID_SIZE_BITS>>,
                                    {ok, {Guid, TotalSize, NextOffset}};
                                {ok, _SomeOtherData} ->
                                    {corrupted, NextOffset};
                                KO -> KO
                            end;
                        {ok, _SomeOtherPos} ->
                            %% seek failed, so give up
                            eof;
                        KO -> KO
                    end
            end;
        Other -> Other
    end.