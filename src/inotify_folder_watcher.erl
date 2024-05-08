-module(inotify_folder_watcher).
-behaviour(gen_server).

-compile(export_all).


%% /* the following are legal, implemented events that user-space can watch for */
%% #define IN_ACCESS           0x00000001  /* File was accessed */
%% #define IN_MODIFY           0x00000002  /* File was modified */
%% #define IN_ATTRIB           0x00000004  /* Metadata changed */
%% #define IN_CLOSE_WRITE      0x00000008  /* Writtable file was closed */
%% #define IN_CLOSE_NOWRITE    0x00000010  /* Unwrittable file closed */
%% #define IN_OPEN             0x00000020  /* File was opened */
%% #define IN_MOVED_FROM       0x00000040  /* File was moved from X */
%% #define IN_MOVED_TO         0x00000080  /* File was moved to Y */
%% #define IN_CREATE           0x00000100  /* Subfile was created */
%% #define IN_DELETE           0x00000200  /* Subfile was deleted */
%% #define IN_DELETE_SELF      0x00000400  /* Self was deleted */
%% 
%% /* the following are legal events.  they are sent as needed to any watch */
%% #define IN_UNMOUNT          0x00002000  /* Backing fs was unmounted */
%% #define IN_Q_OVERFLOW       0x00004000  /* Event queued overflowed */
%% #define IN_IGNORED          0x00008000  /* File was ignored */
%% 
%% /* helper events */
%% #define IN_CLOSE            (IN_CLOSE_WRITE | IN_CLOSE_NOWRITE) /* close */
%% #define IN_MOVE             (IN_MOVED_FROM | IN_MOVED_TO) /* moves */
%% 
%% /* special flags */
%% #define IN_ISDIR            0x40000000  /* event occurred against dir */
%% #define IN_ONESHOT          0x80000000  /* only send event once */


-define(POLL_DELAY, 10).
%% -define(MASK, 16#4000410A). %ISDIR, CREATE, CLOSE_WRITE, Q_OVERFLOW, MODIFY
%% -define(MASK, 16#4000430A). %ISDIR, CREATE, CLOSE_WRITE, Q_OVERFLOW, MODIFY, DELETE
-define(MASK, 0). %% All events

watch_file(Pid, Path) -> Pid ! {watch_file, Path}.
watch_folders(Pid, Folders) -> Pid ! {watch_folders, Folders}.


start_link({Folders, Parent}) -> gen_server:start_link(?MODULE, {Folders, Parent}, []).

init({Folders, Parent}) ->
    {ok, Fd} = inotify:init(),

    self() ! {watch_folders, Folders},
    self() ! tick,

    {ok, #{inotify_fd=> Fd, parent=> Parent, wd_lookup=> #{}}}.


recurse_folders(Fd, []) -> done;
recurse_folders(Fd, [Folder|T]) ->
    AbsFolder = filename:absname(unicode:characters_to_binary(Folder)),
    IsDir = filelib:is_dir(AbsFolder),

    %io:format("abstocheck ~p \n", [AbsFolder]),

    case file:list_dir(AbsFolder) of
        {error, enotdir} -> 
            recurse_folders(Fd, T);

        {error, enoent} when IsDir -> 
            self() ! {watch_file, AbsFolder},
            recurse_folders(Fd, T);

        {error, _} -> 
            recurse_folders(Fd, T);

        {ok, Files} ->
            self() ! {watch_file, AbsFolder},
            Files2 = [filename:join(AbsFolder, unicode:characters_to_binary(X)) || X <- Files],
            recurse_folders(Fd, T++Files2)
    end
    .

wd_lookup_absname(WdLookup, Wd, Filename) -> 
    case maps:get(Wd, WdLookup, undefined) of
        undefined -> {error, notfound};
        Abspath -> filename:join(Abspath, Filename)
    end.


%Add watched folders and recurse them
handle_info({watch_folders, Folders}, S) ->
    Fd = maps:get(inotify_fd, S),
    recurse_folders(Fd, Folders),
    {noreply, S};


%watch single file/folder
handle_info({watch_file, Path}, S) ->
    Fd = maps:get(inotify_fd, S),
    WdLookup = maps:get(wd_lookup, S),

    Absname = filename:absname(Path),
    FileUnicode = filename:absname(Absname),

    {ok, Wd} = inotify:add_watch(Fd, ?MASK, FileUnicode),

    {noreply, S#{wd_lookup=> maps:merge(WdLookup, #{Wd=> FileUnicode})}};

%Remove a watched file descriptor
handle_info({rm_watch, Fd, Wd}, S) -> ok = inotify:rm_watch(Fd, Wd);

handle_info(tick, S) ->
    Fd = maps:get(inotify_fd, S),
    Parent = maps:get(parent, S),
    WdLookup = maps:get(wd_lookup, S),

    case inotify:read(Fd) of
        {error, 11} -> 'EAGAIN', S;
        {error, ErrCode} -> throw({"inotify:read failed with", ErrCode}), S;

        {ok, Events} ->
            lists:foreach(fun(E) ->
                    case E of
                        {inotify, invalid_event} -> pass;
                        {inotify, Wd, Mask, Cookie, Filename} ->
                            %% io:format("[~p] ~p inotify Mask ~p, File ~p~n",[?MODULE, ?FUNCTION_NAME, Mask, Filename]), 
                            IsWritten = lists:member(close_write, Mask),
                            IsDir = lists:member(isdir, Mask),
                            Create = lists:member(create, Mask),
                            Delete = lists:member(delete, Mask),
                            Moved = lists:member(moved_from, Mask),

                            %File written to and changed
                            case {IsDir, IsWritten} of
                                {false, true} -> 
                                    AbsName1 = wd_lookup_absname(WdLookup, Wd, Filename),
                                    Parent ! {inotify, changed, AbsName1};
                                _ -> pass
                            end,
                            
                            % File deleted
                            case {IsDir, Delete} of
                                {false, true} -> 
                                    AbsName3 = wd_lookup_absname(WdLookup, Wd, Filename),
                                    Parent ! {inotify, delete, AbsName3};
                                _ -> pass
                            end,

                            % File moved
                            case {IsDir, Moved} of
                                {false, true} -> 
                                    AbsName4 = wd_lookup_absname(WdLookup, Wd, Filename),
                                    Parent ! {inotify, moved, AbsName4};
                                _ -> pass
                            end,

                            
                            %New directory created, start monitoring it
                            case {IsDir, Create} of
                                {true, true} -> 
                                    AbsName2 = wd_lookup_absname(WdLookup, Wd, Filename),
                                    self() ! {watch_folders, [AbsName2]};
                                _ -> pass
                            end 
                    end
                end, Events
            )
    end,

    erlang:send_after(?POLL_DELAY, self(), tick),
    {noreply, S};

handle_info(Message, S) -> {noreply, S}.

handle_call(Message, From, S) -> {reply, ok, S}.
handle_cast(Message, S) -> {noreply, S}.

terminate(_Reason, S) -> ok.
code_change(_OldVersion, S, _Extra) -> {ok, S}. 
