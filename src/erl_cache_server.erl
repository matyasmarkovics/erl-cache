-module(erl_cache_server).

-behaviour(gen_server).

-include("erl_cache.hrl").
-include("logging.hrl").

%% ==================================================================
%% API Function Exports
%% ==================================================================

-export([
    start_link/1,
    get/3,
    match/3,
    is_valid_name/1,
    set/9,
    evict/3,
    check_mem_usage/1,
    get_stats/1,
    evict_all/2
]).

%% ==================================================================
%% gen_server Function Exports
%% ==================================================================

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(stats, {
    hit     = 0 :: non_neg_integer(),
    miss    = 0 :: non_neg_integer(),
    overdue = 0 :: non_neg_integer(),
    evict   = 0 :: non_neg_integer(),
    set     = 0 :: non_neg_integer()
}).

-type stats() :: #stats{}.
-type stats_field() :: hit|miss|overdue|evict|set.

-record(state, {
    name  :: erl_cache:name(), %% The name of this cache instance
    cache :: ets:tid(),        %% Holds cache
    stats :: stats()           %% Statistics about cache hits
}).

-record(cache_entry, {
    key::undefined|'_'|erl_cache:key(),
    value::undefined|'_'|erl_cache:value(),
    created::undefined|'_'|pos_integer(),
    validity::undefined|'_'|pos_integer(),
    evict::undefined|'_'|'$1'|pos_integer(),
    validity_delta::undefined|'_'|erl_cache:validity(),
    error_validity_delta::undefined|'_'|erl_cache:error_validity(),
    evict_delta::undefined|'_'|erl_cache:evict(),
    refresh_callback::undefined|'_'|erl_cache:refresh_callback(),
    is_error_callback::undefined|'_'|erl_cache:is_error_callback()
}).

-type cache_operation()::fun((erl_cache:cache_name(), #cache_entry{}) -> non_neg_integer()).

%% ==================================================================
%% API Function Definitions
%% ==================================================================

-spec start_link(erl_cache:name()) -> {ok, pid()}.
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, Name, []).

-spec get(erl_cache:name(), erl_cache:key(), erl_cache:wait_for_refresh()) ->
    {ok, erl_cache:value()} | {error, not_found}.
get(Name, Key, WaitForRefresh) ->
    Now = now_ms(),
    case ets:lookup(get_table_name(Name), Key) of
        [Entry] ->
            send_stat(Name, Now, Entry),
            case get_valid_value(Name, WaitForRefresh, Now, Entry) of
                {true, Value} -> {ok, Value};
                false -> {error, not_found}
            end;
        [] ->
            send_stat(Name, Now, #cache_entry{}),
            {error, not_found}
    end.

send_stat(Name, _Now, #cache_entry{key=undefined}) ->
    gen_server:cast(Name, {increase_stat, miss});
send_stat(Name, Now, #cache_entry{validity=Validity}) when Now < Validity ->
    gen_server:cast(Name, {increase_stat, hit});
send_stat(Name, Now, #cache_entry{evict=Evict}) when Now < Evict ->
    gen_server:cast(Name, {increase_stat, overdue});
send_stat(_Name, _Now,  _) ->
    ok.

get_valid_value(_Name, _IsSync, Now, #cache_entry{validity=Validity} = E) when Now < Validity ->
    {true, E#cache_entry.value};
get_valid_value(Name, IsSync, Now, #cache_entry{evict=Evict} = E) when Now < Evict ->
    refresh(Name, E, IsSync);
get_valid_value(_Name, _IsSync, _Now, #cache_entry{value=_ExpiredValue}) ->
    false.

-spec match(erl_cache:name(), erl_cache:key(), erl_cache:wait_for_refresh()) ->
    {ok, erl_cache:value()} | {error, not_found}.
match(Name, Key, WaitForRefresh) ->
    Now = now_ms(),
    case ets:match_object(get_table_name(Name), #cache_entry{key = Key, _ = '_'}) of
        [] ->
            send_stat(Name, Now, #cache_entry{}),
            {error, not_found};
        Matches ->
            IsValid = fun(E) ->
                          send_stat(Name, Now, E),
                          get_valid_value(Name, WaitForRefresh, Now, E)
                      end,
            case lists:filtermap(IsValid, Matches) of
                [] -> {error, not_found};
                Values -> {ok, Values}
            end
    end.

-spec set(erl_cache:name(), erl_cache:key(), erl_cache:value(), pos_integer(), non_neg_integer(),
          erl_cache:refresh_callback(), erl_cache:wait_until_done(), erl_cache:error_validity(),
          erl_cache:is_error_callback()) -> ok.
set(Name, Key, Value, ValidityDelta, EvictDelta,
    RefreshCb, WaitTillSet, ErrorValidityDelta, IsErrorCb) ->
    Now = now_ms(),
    {Validity, Evict} = case is_error_value(IsErrorCb, Value) of
        false -> {Now + ValidityDelta, Now + ValidityDelta + EvictDelta};
        true -> {Now + ErrorValidityDelta, Now + ErrorValidityDelta}
    end,
    Entry = #cache_entry{
        key = Key,
        value = Value,
        created = Now,
        validity = Validity,
        error_validity_delta = ErrorValidityDelta,
        evict = Evict,
        validity_delta = ValidityDelta,
        evict_delta = EvictDelta,
        refresh_callback = RefreshCb,
        is_error_callback = IsErrorCb
    },
    operate_cache(Name, fun do_set/2, Entry, set, WaitTillSet).

-spec evict(erl_cache:name(), erl_cache:key(), erl_cache:wait_until_done()) -> ok.
evict(Name, Key, WaitUntilDone) ->
    operate_cache(Name, fun do_evict/2, #cache_entry{key=Key, _='_'}, evict, WaitUntilDone).

-spec get_stats(erl_cache:name()) -> erl_cache:cache_stats().
get_stats(Name) ->
    Info = ets:info(get_table_name(Name)),
    Memory = proplists:get_value(memory, Info, 0),
    Entries = proplists:get_value(size, Info, 0),
    ServerStats = gen_server:call(Name, get_stats),
    [{entries, Entries}, {memory, Memory}] ++ ServerStats.

-spec is_valid_name(erl_cache:name()) -> boolean().
is_valid_name(Name) ->
    not lists:member(get_table_name(Name), ets:all()).

-spec evict_all(erl_cache:name(), boolean()) -> ok.
evict_all(Name, WaitUntilDone) ->
    operate_cache(Name, fun do_evict_all/2, #cache_entry{_='_'}, evict, WaitUntilDone).

%% ==================================================================
%% gen_server Function Definitions
%% ==================================================================

%% @private
-spec init(erl_cache:name()) -> {ok, #state{}}.
init(Name) ->
    CacheTid = ets:new(get_table_name(Name), [set, public, named_table, {keypos,2},
                                              {read_concurrency, true},
                                              {write_concurrency, true}]),
    EvictInterval = erl_cache:get_cache_option(Name, evict_interval),
    {ok, _} = timer:send_after(EvictInterval, Name, purge_cache),
    MemCheckInterval = erl_cache:get_cache_option(Name, mem_check_interval),
    {ok, _} = timer:apply_after(MemCheckInterval, ?MODULE, check_mem_usage, [Name]),
    {ok, #state{name=Name, cache=CacheTid, stats=#stats{}}}.

%% @private
-spec handle_call(term(), term(), #state{}) ->
    {reply, Data::any(), #state{}}.
handle_call(get_stats, _From, #state{stats=Stats} = State) ->
    {reply, stats_to_list(Stats), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%% @private
-spec handle_cast(any(), #state{}) -> {noreply, #state{}}.
handle_cast({increase_stat, Stat}, #state{stats=Stats} = State) ->
    {noreply, State#state{stats=update_stats(Stat, Stats)}};
handle_cast({increase_stat, Stat, N}, #state{stats=Stats} = State) ->
    {noreply, State#state{stats=update_stats(Stat, N, Stats)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
-spec handle_info(any(), #state{}) -> {noreply, #state{}}.
handle_info(purge_cache, #state{name=Name} = State) ->
    purge_cache(Name),
    EvictInterval = erl_cache:get_cache_option(Name, evict_interval),
    {ok, _} = timer:send_after(EvictInterval, Name, purge_cache),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
-spec terminate(any(), #state{}) -> any().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(any(), #state{}, any()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal Function Definitions
%% ====================================================================

%% @private
-spec operate_cache(Name, Function, Entry, Stat, boolean()) -> ok when
      Name::erl_cache:name(),
      Function::cache_operation(),
      Entry::#cache_entry{},
      Stat::stats_field().
operate_cache(Name, Function, Entry, Stat, true) ->
    N = Function(Name, Entry),
    ok = gen_server:cast(Name, {increase_stat, Stat, N});
operate_cache(Name, Function, Entry, Stat, false) ->
    spawn_link(fun() -> operate_cache(Name, Function, Entry, Stat, true) end),
    ok.

%% @private
-spec do_set(erl_cache:name(), #cache_entry{}) -> non_neg_integer().
do_set(Name, Entry) ->
    true = ets:insert(get_table_name(Name), Entry),
    1.

%% @private
-spec do_evict(erl_cache:name(), #cache_entry{}) -> non_neg_integer().
do_evict(Name, #cache_entry{key=Key}) ->
    true = ets:delete(get_table_name(Name), Key),
    1.

-spec do_evict_all(erl_cache:name(), #cache_entry{}) -> non_neg_integer().
do_evict_all(Name, _Entry) ->
    ets:select_delete(get_table_name(Name), [{'_', [], [true]}]).

%% @private
-spec purge_cache(erl_cache:name()) -> ok.
purge_cache(Name) ->
    Owner = ets:info(get_table_name(Name), owner),
    MatchPattern = #cache_entry{_='_'},
    %% make sure the table has not disappeared out from under us
    [operate_cache(Name, fun tc_purge_cache/2, MatchPattern, evict, true) || is_pid(Owner)],
    ok.

tc_purge_cache(Name, EntryPattern) ->
    {_Time, Deleted} = timer:tc(fun do_purge_cache/2, [Name, EntryPattern]),
    ?DEBUG("~p cache purged in ~bms", [Name, _Time]),
    Deleted.

do_purge_cache(Name, EntryPattern) ->
    Now = now_ms(),
    MatchPattern = EntryPattern#cache_entry{evict='$1'},
    Conditionals = [{'<', '$1', Now}],
    ets:select_delete(get_table_name(Name), [{MatchPattern, Conditionals, [true]}]).

%% @private
-spec refresh(erl_cache:name(), #cache_entry{}, erl_cache:wait_for_refresh()) ->
    {true, erl_cache:value()}.
refresh(_Name, #cache_entry{refresh_callback=undefined} = Entry, _WaitForRefresh) ->
    {true, Entry#cache_entry.value};
refresh(Name, #cache_entry{} = Entry, true) ->
    NewEntry = maybe_refresh(Name, Entry),
    operate_cache(Name, fun do_set/2, NewEntry, set, false),
    {true, NewEntry#cache_entry.value};
refresh(Name, #cache_entry{} = Entry, false) ->
    operate_cache(Name, fun(N, E) -> do_set(N, maybe_refresh(N, E)) end, Entry, set, false),
    {true, Entry#cache_entry.value}.

%% @private
-spec maybe_refresh(erl_cache:name(), #cache_entry{}) -> #cache_entry{}.
maybe_refresh(Name, #cache_entry{refresh_callback=Callback, is_error_callback=IsErrorCb} = E) ->
    ?DEBUG("Refreshing overdue key ~p in cache: ~p", [E#cache_entry.key, Name]),
    % Consider wraping in try-catch
    Value = do_apply(Callback),
    case is_error_value(IsErrorCb, Value) of
        false ->
            Now = now_ms(),
            Validity = Now+E#cache_entry.validity_delta,
            Evict = Validity+E#cache_entry.evict_delta,
            E#cache_entry{value=Value, validity=Validity, evict=Evict};
        true ->
            ?NOTICE("Error refreshing ~p at ~p: ~p. Disabling auto refresh...",
                    [E#cache_entry.key, Name, Value]),
            % Consider setting validity by error_validity_delta
            E#cache_entry{refresh_callback=undefined}
    end.

%% @private
-spec check_mem_usage(erl_cache:name()) -> ok.
check_mem_usage(Name) ->
    TableName = get_table_name(Name),
    %% make sure the table has not disappeared out from under us
    case ets:info(TableName, memory) of
        undefined -> ok;
        CurrentWords -> check_mem_usage( Name, CurrentWords )
    end.

check_mem_usage( Name, CurrentWords ) ->
    MaxMB = erl_cache:get_cache_option(Name, max_cache_size),
    CurrentMB = (CurrentWords * erlang:system_info(wordsize)) div (1024 * 1024),
    case MaxMB /= undefined andalso CurrentMB > MaxMB of
        true ->
            ?WARNING("~p exceeded memory limit of ~pMB: ~pMB in use! Forcing eviction...",
                     [Name, MaxMB, CurrentMB]),
            purge_cache(Name);
        false -> ok
    end,
    MemCheckInterval = erl_cache:get_cache_option(Name, mem_check_interval),
    {ok, _} = timer:apply_after(MemCheckInterval, ?MODULE, check_mem_usage, [Name]),
    ok.

%% @private
-spec do_apply(erl_cache:refresh_callback()) -> term().
do_apply({M, F, A}) when is_atom(M), is_atom(F), is_list(A) ->
    apply(M, F, A);
do_apply({F, A}) when is_function(F, length(A)) ->
    apply(F, A);
do_apply(F) when is_function(F) ->
    F().

%% @private
-spec is_error_value(erl_cache:is_error_callback(), erl_cache:value()) -> boolean().
is_error_value({M, F, A}, Value) ->
    apply(M, F, [Value|A]);
is_error_value({F, A}, Value) ->
    apply(F, [Value|A]);
is_error_value(F, Value) when is_function(F) ->
    F(Value).

%% @private
-spec update_stats(hit|miss|overdue|evict|set, stats()) -> stats().
update_stats(Stat, Stats) ->
    update_stats(Stat, 1, Stats).

%% @private
-spec update_stats(hit|miss|overdue|evict|set, pos_integer(), stats()) -> stats().
update_stats(hit,     N, S) -> S#stats{hit       = S#stats.hit     + N};
update_stats(miss,    N, S) -> S#stats{miss      = S#stats.miss    + N};
update_stats(overdue, N, S) -> S#stats{overdue   = S#stats.overdue + N};
update_stats(evict,   N, S) -> S#stats{evict     = S#stats.evict   + N};
update_stats(set,     N, S) -> S#stats{set       = S#stats.set     + N}.

stats_to_list(#stats{hit     = Hit,
                     miss    = Miss,
                     overdue = Overdue,
                     evict   = Evict,
                     set     = Set}) ->
    [{total_ops, Hit + Miss + Overdue + Evict + Set},
     {hit,       Hit},
     {miss,      Miss},
     {overdue,   Overdue},
     {evict,     Evict},
     {set,       Set}].

%% @private
-spec now_ms() -> pos_integer().
now_ms() ->
    {Mega, Sec, Micro} = os:timestamp(),
    Mega * 1000000000 + Sec * 1000 + Micro div 1000.

%% @private
-spec get_table_name(erl_cache:name()) -> atom().
get_table_name(Name) ->
    to_atom(atom_to_list(Name) ++ "_ets").

%% @private
-spec to_atom(string()) -> atom().
to_atom(Str) ->
    try list_to_existing_atom(Str) catch error:badarg -> list_to_atom(Str) end.

