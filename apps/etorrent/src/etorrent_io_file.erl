%% @author Magnus Klaar <magnus.klaar@gmail.com>
%% @doc File handle state machine.
%%
%% <p>
%% State machine that wraps a file-handle and exposes an interface
%% that enables clients to read and write data at specified offsets.
%% An previously unstated benefit of using a server process to wrap
%% a file handle is that the file handle is cached and reused. This
%% reduces the number of open file handles to at most one per file
%% instead of requiring one file handle per concurrent request.
%% </p>
%%
%% <p>
%% The state machine is a simple model of the open/closed state of the
%% file handle which simplifies request handling and reduces the average
%% number of calls sent to the directory server. The worst case is still
%% at least one call to request permission to open the file.
%% </p>
%%
%% @end
-module(etorrent_io_file).
-behaviour(gen_fsm).
-define(GC_TIMEOUT, 5000).

%% exported functions
-export([start_link/3,
         open/1,
         close/1,
         read/3,
         write/3,
         allocate/2]).

%% gen_fsm callbacks and states
-export([init/1,
         closed/2,
         closed/3,
         opening/2,
         opening/3,
         opened/2,
         opened/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).


-type torrent_id() :: etorrent_types:torrent_id().
-type file_path() :: etorrent_types:file_path().
-type block_len() :: etorrent_types:block_len().
-type block_bin() :: etorrent_types:block_bin().
-type block_offset() :: etorrent_types:block_offset().

-record(state, {
    torrent :: torrent_id(),
    handle=closed :: closed | file:io_device(),
    rqueue   :: queue(),
    wqueue   :: queue(),
    relpath  :: file_path(),
    fullpath :: file_path()}).


-define(CALL_TIMEOUT, timer:seconds(30)).

%% @doc Start the file wrapper server
%% <p>Of the two paths given, one is the partial path used internally
%% and the other is the full path where to store the file in question.</p>
%% @end
-spec start_link(torrent_id(), file_path(), file_path()) -> {'ok', pid()}.
start_link(TorrentID, Path, FullPath) ->
    FsmOpts = [{spawn_opt, [{fullsweep_after, 0}]}],
    gen_fsm:start_link(?MODULE, [TorrentID, Path, FullPath], FsmOpts).

%% @doc Request to open the file
%% @end
-spec open(pid()) -> 'ok'.
open(FilePid) ->
    gen_fsm:send_event(FilePid, open).

%% @doc Request to close the file
%% @end
-spec close(pid()) -> 'ok'.
close(FilePid) ->
    gen_fsm:send_event(FilePid, close).

%% @doc Read bytes from file handle
%% <p>Read `Length' bytes from filehandle at `Offset'</p>
%% @end
-spec read(pid(), block_offset(), block_len()) ->
          {ok, block_bin()} | {error, eagain}.
read(FilePid, Offset, Length) ->
    gen_fsm:sync_send_event(FilePid, {read, Offset, Length}, ?CALL_TIMEOUT).

%% @doc Write bytes to file
%% <p>Assume that the `Chunk' is of binary() type. Write it to the
%% file at `Offset'</p>
%% @end
-spec write(pid(), block_offset(), block_bin()) ->
          ok | {error, eagain}.
write(FilePid, Offset, Chunk) ->
    gen_fsm:sync_send_event(FilePid, {write, Offset, Chunk}, ?CALL_TIMEOUT).

%% @doc Allocate the file up to the given size
%% @end
-spec allocate(pid(), integer()) -> ok.
allocate(FilePid, Size) ->
    gen_fsm:sync_send_event(FilePid, {allocate, Size}, infinity).

%% @private
init([TorrentID, RelPath, FullPath]) ->
    true = etorrent_io:register_file_server(TorrentID, RelPath),
    InitState = #state{
        torrent=TorrentID,
        handle=closed,
        rqueue=queue:new(),
        wqueue=queue:new(),
        relpath=RelPath,
        fullpath=FullPath},
    {ok, closed, InitState}.


%% @private handle asynchronous event in closed state.
closed({read, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, closed, State, ?GC_TIMEOUT};
closed({write, _, _}, _, State) when State#state.handle == closed ->
    {reply, {error, eagain}, closed, State, ?GC_TIMEOUT};

closed({read, Offset, Length}, _, State) ->
    #state{handle=Handle} = State,
    {ok, Chunk} = file:pread(Handle, Offset, Length),
    {reply, {ok, Chunk}, closed, State, ?GC_TIMEOUT};

closed({write, Offset, Chunk}, _, State) ->
    #state{handle=Handle} = State,
    ok = file:pwrite(Handle, Offset, Chunk),
    {reply, ok, closed, State, ?GC_TIMEOUT};

closed({allocate, _Sz}, _From, #state { handle = closed } = S) ->
    {reply, {error, eagain}, closed, S, ?GC_TIMEOUT};

closed({allocate, Sz}, _From, #state { handle = FD } = S) ->
    fill_file(FD, Sz),
    {reply, ok, closed, S, ?GC_TIMEOUT}.

%% @private handle synchronous event in closed state.
closed(open, State) ->
    #state{
        torrent=Torrent,
        handle=closed,
        relpath=RelPath,
        fullpath=FullPath} = State,
    true = etorrent_io:register_open_file(Torrent, RelPath),
    FileOpts = [read, write, binary, raw, read_ahead,
                {delayed_write, 1024*1024, 3000}],
    ok = filelib:ensure_dir(FullPath),
    {ok, Handle} = file:open(FullPath, FileOpts),
    NewState = State#state{handle=Handle},
    {next_state, closed, NewState, ?GC_TIMEOUT};

closed(close, State) ->
    #state{
        torrent=Torrent,
        handle=Handle,
        relpath=RelPath} = State,
    true = etorrent_io:unregister_open_file(Torrent, RelPath),
    ok = file:close(Handle),
    NewState = State#state{handle=closed},
    {next_state, closed, NewState, ?GC_TIMEOUT};

closed(timeout, State) ->
    true = erlang:garbage_collect(),
    {next_state, closed, State}.


%% @private handle asynchronous event in opening state.
opening(Msg, State) ->
    {stop, Msg, State}.


%% @private handle synchronous event in opening state.
opening(Msg, _From, State) ->
    {stop, Msg, State}.


%% @private handle asynchronous event in opened state.
opened(Msg, State) ->
    {stop, Msg, State}.


%% @private handle synchronous event in opened state.
opened(Msg, _From, State) ->
    {stop, Msg, State}.


%% @private
handle_event(_Msg, _Statename, _State) ->
    not_implemented.

%% @private
handle_sync_event(_Msg, _From, _Statename, _State) ->
    not_implemented.

%% @private
handle_info(_Msg, _Statename, _State) ->
    not_implemented.

%% @private
terminate(_Reason, _Statename, _State) ->
    not_implemented.

%% @private
code_change(_OldVsn, _Statename, _State, _Extra) ->
    not_implemented.


fill_file(FD, Missing) ->
    case application:get_env(etorrent, preallocation_strategy) of
	undefined -> fill_file_sparse(FD, Missing);
	{ok, sparse} -> fill_file_sparse(FD, Missing);
	{ok, preallocate} -> fill_file_prealloc(FD, Missing)
    end.

fill_file_sparse(FD, Missing) ->
    {ok, _NP} = file:position(FD, {eof, Missing-1}),
    ok = file:write(FD, <<0:8>>).

fill_file_prealloc(FD, N) ->
    {ok, _NP} = file:position(FD, eof),
    SZ4 = N div 4,
    Rem = (N rem 4) * 8,
    create_file(FD, 0, SZ4),
    ok = file:write(FD, <<0:Rem/unsigned>>).

create_file(_FD, M, M) ->
           ok;
create_file(FD, M, N) when M + 1024 =< N ->
    create_file(FD, M, M + 1024, []),
    create_file(FD, M + 1024, N);
create_file(FD, M, N) ->
    create_file(FD, M, N, []).

create_file(FD, M, M, R) ->
    ok = file:write(FD, R);
create_file(FD, M, N0, R) when M + 8 =< N0 ->
    N1  = N0-1,  N2  = N0-2,  N3  = N0-3,  N4  = N0-4,
    N5  = N0-5,  N6  = N0-6,  N7  = N0-7,  N8  = N0-8,
    create_file(FD, M, N8,
		[<<N8:32/unsigned,  N7:32/unsigned,
		   N6:32/unsigned,  N5:32/unsigned,
		   N4:32/unsigned,  N3:32/unsigned,
		   N2:32/unsigned,  N1:32/unsigned>> | R]);
create_file(FD, M, N0, R) ->
    N1 = N0-1,
    create_file(FD, M, N1, [<<N1:32/unsigned>> | R]).














