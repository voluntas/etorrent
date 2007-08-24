%%%-------------------------------------------------------------------
%%% File    : metainfo.erl
%%% Author  : Jesper Louis Andersen <jlouis@succubus>
%%% License : See COPYING
%%% Description : Code for manipulating the metainfo file
%%%
%%% Created : 24 Jan 2007 by Jesper Louis Andersen <jlouis@succubus>
%%%-------------------------------------------------------------------

%% TODO: A couple of functions in metainfo doesn't belong here. They
%%   they should be moved into bcoding.

-module(etorrent_metainfo).
-author("Jesper Louis Andersen <jesper.louis.andersen@gmail.com>").
-vsn(1).

%% API
-export([get_piece_length/1, get_pieces/1, get_url/1, get_infohash/1,
	 parse/1, get_files/1, get_name/1, hexify/1]).

%%====================================================================
%% API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: get_piece_length/1
%% Description: Search a torrent file, return the piece length
%%--------------------------------------------------------------------
get_piece_length(Torrent) ->
    {integer, Size} = find_target(get_info(Torrent), "piece length"),
    Size.

%%--------------------------------------------------------------------
%% Function: get_pieces/1
%% Description: Search a torrent, return pieces as a list
%%--------------------------------------------------------------------
get_pieces(Torrent) ->
    case find_target(get_info(Torrent), "pieces") of
	{string, Ps} ->
	    lists:map(fun(Str) -> list_to_binary(Str) end,
		      split_into_chunks(20, [], Ps))
    end.

get_length(Torrent) ->
    case find_target(get_info(Torrent), "length") of
	{integer, L} ->
	    L
    end.

%%--------------------------------------------------------------------
%% Function: get_files/1
%% Description: Get a file list from the torrent
%%--------------------------------------------------------------------
get_files(Torrent) ->
    {list, FilesEntries} = get_files_section(Torrent),
    process_paths(FilesEntries, []).


%%--------------------------------------------------------------------
%% Function: get_name/1
%% Description: Get the name of a torrent. Returns either {ok, N} for
%%   for a valid name or {error, security_violation, N} for something
%%   that violates the security limitations.
%%--------------------------------------------------------------------
get_name(Torrent) ->
    {string, N} = find_target(get_info(Torrent), "name"),
    case valid_path(N) of
	true ->
	    {ok, N};
	false ->
	    {error, security_violation, N}
    end.

%%--------------------------------------------------------------------
%% Function: get_url/1
%% Description: Return the URL of a torrent
%%--------------------------------------------------------------------
get_url(Torrent) ->
    case find_target(Torrent, "announce") of
	{string, U} -> U
    end.

%%--------------------------------------------------------------------
%% Function: get_infohash/1
%% Description: Return the infohash for a torrent
%%--------------------------------------------------------------------
get_infohash(Torrent) ->
    {ok, InfoDict} = etorrent_bcoding:search_dict({string, "info"}, Torrent),
    {ok, InfoString} = etorrent_bcoding:encode(InfoDict),
    crypto:sha(list_to_binary(InfoString)).

%%--------------------------------------------------------------------
%% Function: parse/1
%% Description: Parse a file into a Torrent structure.
%%--------------------------------------------------------------------
parse(File) ->
    case file:open(File, [read]) of
	{ok, IODev} ->
	    Data = read_data(IODev),
	    ok = file:close(IODev),
	    case etorrent_bcoding:decode(Data) of
		{ok, Torrent} ->
		    {ok, Torrent};
		{error, Reason} ->
		    {not_a_torrent, Reason}
	    end;
	{error, Reason} ->
	    {could_not_read_file, Reason}
    end.
%%====================================================================
%% Internal functions
%%====================================================================

%% Find a target that can't fail
find_target(D, Name) ->
    case etorrent_bcoding:search_dict({string, Name}, D) of
	{ok, X} ->
	    X
    end.

get_info(Torrent) ->
    find_target(Torrent, "info").


split_into_chunks(_N, Accum, []) ->
    lists:reverse(Accum);
split_into_chunks(N, Accum, String) ->
    {Chunk, Rest} = lists:split(N, String),
    split_into_chunks(N, [Chunk | Accum], Rest).

read_data(IODev) ->
    eat_lines(IODev, []).

eat_lines(IODev, Accum) ->
    case io:get_chars(IODev, ">", 8192) of
	eof ->
	    lists:concat(lists:reverse(Accum));
	String ->
	    eat_lines(IODev, [String | Accum])
    end.

%% TODO: Implement the protocol for alternative URLs at some point.

hexify(Digest) ->
    Characters = lists:map(fun(Item) ->
				   lists:concat(io_lib:format("~.16B",
							      [Item])) end,
			   binary_to_list(Digest)),
    lists:concat(Characters).

valid_path(Path) ->
    RE = "^[^/\\.~][^\\/]*$",
    case regexp:match(Path, RE) of
	{match, _S, _E} ->
	    true;
	nomatch ->
	    false
    end.

process_file_entry(Entry) ->
    {dict, Dict} = Entry,
    {value, {{string, "path"},
	     {list, Path}}} =
	lists:keysearch({string, "path"}, 1, Dict),
    {value, {{string, "length"},
	     {integer, Size}}} =
	lists:keysearch({string, "length"}, 1, Dict),
    case lists:any(fun({string, P}) -> valid_path(P) end, Path) of
	true ->
	    Filename =
		filename:join(lists:map(fun({string, X}) -> X end, Path)),
	    {ok, {Filename, Size}};
	false ->
	    {error, security_violation, Path}
    end.

process_paths([], Accum) ->
    {ok, lists:reverse(Accum)};
process_paths([E | Rest], Accum) ->
    case process_file_entry(E) of
	{ok, NameSize} ->
	    process_paths(Rest, [NameSize | Accum]);
	{error, security_violation, Path} ->
	    % Escape
	    {error, security_violation, Path}
    end.

get_files_section(Torrent) ->
    case etorrent_bcoding:search_dict({string, "files"}, get_info(Torrent)) of
	{ok, X} ->
	    X;
	false ->
	    % Single value torrent, fake entry
	    N = get_name(Torrent),
	    L = get_length(Torrent),
	    {list,[{dict,[{{string,"path"},
			   {list,[{string,N}]}},
			  {{string,"length"},{integer,L}}]}]}
    end.