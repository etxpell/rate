
-module(sysRate_test).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).




%%------------------
%% Simple meter cases

start_stop_test() ->
    Res = sysRate:start_link(),
    ?assertMatch({ok, _}, Res),
    {ok, Pid} = Res,
    ?assertEqual(true, is_pid(Pid)),
    ?assertEqual(true, is_pid(whereis(sysRate))),
    StopRes = sysRate:stop(),
    ?assertEqual(StopRes, ok),
    ?assertEqual(false, is_pid(whereis(sysRate))).


define_test() ->
    preamble(),
    ResFalse = sysRate:is_limiter_running(lim1),
    ?assertEqual(false, ResFalse),
    sysRate:create(lim1, []),
    ResTrue = sysRate:is_limiter_running(lim1),
    ?assertEqual(true, ResTrue),
    postamble().

simple_rate_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:create(lim1, [{rate, 1}, manual_tick]),
    Res = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res),
    postamble().

rate_tick_once_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:create(lim1, [{rate, 2}, manual_tick, {period, 500}]),
    Res1 = do_n_requests(lim1, 5),
    Expected1 = [true, true, false, false, false],
    ?assertEqual(Expected1, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 5),
    Expected2 = [true, false, false, false, false],
    ?assertEqual(Expected2, Res2),
    postamble().

rate_tick_uneven_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 300}]),
    ExpectedOne = [true, false, false],
    ExpectedNone = [false, false, false],
    
    Res1 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res2),
    sysRate:tick(lim1),
    Res3 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res3),
    sysRate:tick(lim1),
    Res4 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res4),
    sysRate:tick(lim1),
    Res5 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res5),
    sysRate:tick(lim1),
    Res6 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res6),

    postamble().

check_many_rates_test_() ->
    {foreach,
     fun() -> preamble() end,
     fun(_) -> postamble() end,
     [
      {"rate=10, period=50",
       fun() -> run_bucket(10, 50) end},
      {"rate=10, period=73",
       fun() -> run_bucket(10, 73) end},
      {"rate=10, period=100",
       fun() -> run_bucket(10, 100) end},
      {"rate=10, period=200",
       fun() -> run_bucket(10, 200) end},
      {"rate=10, period=300",
       fun() -> run_bucket(10, 300) end},
      {"rate=10, period=130",
       fun() -> run_bucket(10, 130) end},
      {"rate=10, period=470",
       fun() -> run_bucket(10, 470) end},
      {"rate=10, period=512",
       fun() -> run_bucket(10, 512) end},
      {"rate=10, period=830",
       fun() -> run_bucket(10, 830) end},
      {"dummy", fun() -> ok end} ]}.

check_many_high_rates_test_() ->
    {foreach,
     fun() -> preamble() end,
     fun(_) -> postamble() end,
     [
      {"rate=100, period=50",
       fun() -> run_bucket(100, 50) end},
      {"rate=100, period=73",
       fun() -> run_bucket(100, 73) end},
      {"rate=100, period=100",
       fun() -> run_bucket(100, 100) end},
      {"rate=100, period=200",
       fun() -> run_bucket(100, 200) end},
      {"rate=100, period=300",
       fun() -> run_bucket(100, 300) end},
      {"rate=100, period=130",
       fun() -> run_bucket(100, 130) end},
      {"rate=100, period=470",
       fun() -> run_bucket(100, 470) end},
      {"rate=100, period=512",
       fun() -> run_bucket(100, 512) end},
      {"rate=100, period=830",
       fun() -> run_bucket(100, 830) end},
      {"dummy", fun() -> ok end} ]}.

run_bucket(Rate, Period) ->
    sysRate:create(lim1, [{rate, Rate}, manual_tick, {period, Period}]),
    Revoultions = 20*(1+round(1000 / Period)),
    TotTime = ((Revoultions)*Period/1000),
    Ok = ok_count(tl(do_run_bucket(lim1, Revoultions, Rate))),
    ActualRate = one_decimal(Ok/(TotTime)),
    %% io:format("Revs: ~p, tot time: ~p, tot: ~p, rate: ~p~n", 
    %%           [Revoultions, TotTime, Ok, ActualRate]),
    ExpectedRate = one_decimal(Rate),
    ?assertEqual(ExpectedRate, ActualRate).


check_many_rates_prio_test_() ->
    {foreach,
     fun() -> preamble() end,
     fun(_) -> postamble() end,
     [
      {"rate=10, period=50",
       fun() -> run_bucket_prio(10, 50) end},
      {"rate=10, period=73",
       fun() -> run_bucket(10, 73) end},
      {"rate=10, period=100",
       fun() -> run_bucket(10, 100) end},
      {"rate=10, period=200",
       fun() -> run_bucket(10, 200) end},
      {"rate=10, period=300",
       fun() -> run_bucket(10, 300) end},
      {"rate=10, period=130",
       fun() -> run_bucket(10, 130) end},
      {"rate=10, period=470",
       fun() -> run_bucket(10, 470) end},
      {"rate=10, period=512",
       fun() -> run_bucket(10, 512) end},
      {"rate=10, period=830",
       fun() -> run_bucket(10, 830) end},
      {"dummy", fun() -> ok end} ]}.

run_bucket_prio(Rate, Period) ->
    sysRate:create(lim1, [{rate, Rate}, manual_tick, {period, Period}]),
    Revoultions = 20*(1+round(1000 / Period)),
    TotTime = ((Revoultions)*Period/1000),
    Ok = ok_count(tl(do_run_bucket_prio(lim1, Revoultions, Rate))),
    ActualRate = one_decimal(Ok/(TotTime)),
    %% io:format("Revs: ~p, tot time: ~p, tot: ~p, rate: ~p~n", 
    %%           [Revoultions, TotTime, Ok, ActualRate]),
    ExpectedRate = one_decimal(Rate),
    ?assertEqual(ExpectedRate, ActualRate).

limiter_crash_restart_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    exit(sysRate:limiter_pid(lim1), kill),
    timer:sleep(100),
    Res2 = do_n_requests(lim1, 5),
    ?assertEqual(Expected, Res2),
    postamble().

limiter_config_survives_crash_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    ?assertMatch([_, _, _, {rate, 1}|_], sysRate:list_limiter(lim1)),
    sysRate:set_rate(lim1, 2),
    ?assertMatch([_, _, _, {rate, 2}|_], sysRate:list_limiter(lim1)),
    exit(sysRate:limiter_pid(lim1), kill),
    timer:sleep(100),
    ?assertMatch([_, _, _, {rate, 2}|_], sysRate:list_limiter(lim1)),
    postamble().


reconfig_rate_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 500}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    sysRate:set_rate(lim1, 2),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 5),
    Expected2 = [true, true, false, false, false],
    ?assertEqual(Expected2, Res2),
    postamble().


counter_good_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 1),
    Expected = [true],
    ?assertEqual(Expected, Res1),
    Counters = sysRate:read_counters(lim1),
    ?assertEqual({1,0}, Counters),
    ?assertEqual(1,  sysRate:read_counter_good(lim1)),
    ?assertEqual(0,  sysRate:read_counter_rejected(lim1)),
    postamble().

counter_reject_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 2),
    Expected = [true, false],
    ?assertEqual(Expected, Res1),
    Counters = sysRate:read_counters(lim1),
    ?assertEqual({1,1}, Counters),
    ?assertEqual(1,  sysRate:read_counter_good(lim1)),
    ?assertEqual(1,  sysRate:read_counter_rejected(lim1)),
    postamble().


two_limiters_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    sysRate:create(lim2, [{rate, 6}, manual_tick, {period, 200}]),
    Res1a = do_n_requests(lim1, 5),
    Expected1a = [true, false, false, false, false],
    ?assertEqual(Expected1a, Res1a),
    Res2a = do_n_requests(lim2, 7),
    Expected2a = [true, true, true, true, true, true, false],
    ?assertEqual(Expected2a, Res2a),
    sysRate:tick(lim1),
    ?assertEqual([false], do_n_requests(lim2, 1)),

    Res1b = do_n_requests(lim1, 5),
    Expected1b = [false, false, false, false, false],
    ?assertEqual(Expected1b, Res1b),
    sysRate:tick(lim2),
    Res2b = do_n_requests(lim2, 7),
    Expected2b = [true, false, false, false, false, false, false],
    ?assertEqual(Expected2b, Res2b),

    CounterExpect1 = {1, 9},
    ?assertEqual(CounterExpect1, sysRate:read_counters(lim1)),
    CounterExpect2 = {7, 8},
    ?assertEqual(CounterExpect2, sysRate:read_counters(lim2)),
    
    postamble().


list_all_limiters_list_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res = sysRate:list_all_limiters(),
    ?assertMatch([_], Res),
    Lim = hd(Res),
    ?assertMatch([{name, lim1}, {state, on}, {type, meter}, {rate, 1} |_],
                 Lim),
    ?assertEqual(0, gv(good, Lim)),
    ?assertEqual(0, gv(rejected, Lim)).


two_limiters_list_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = sysRate:list_all_limiters(),
    ?assertMatch([[{name, lim1} |_]], Res1),
    
    sysRate:create(lim2, [{rate, 3}, manual_tick, {period, 100}]),
    Res2 = sysRate:list_all_limiters(),
    ?assertMatch([[{name, lim1}, _, _, {rate, 1} |_],
                  [{name, lim2}, _, _, {rate, 3} |_]],
                 Res2),
    postamble().


on_off_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 400}]),
    ExpectedOne = [true, false, false, false, false],
    ExpectedNone = [false, false, false, false, false],
    ExpectedAll = [true, true, true, true, true],

    Res1 = do_n_requests(lim1, 5),
    ?assertEqual(ExpectedOne, Res1),
    
    sysRate:off(lim1),

    Res2 = do_n_requests(lim1, 5),
    ?assertEqual(ExpectedAll, Res2),

    sysRate:on(lim1),
    Res3 = do_n_requests(lim1, 5),
    ?assertEqual(ExpectedOne, Res3),
    
    sysRate:tick(lim1),
    Res4 = do_n_requests(lim1, 5),
    ?assertEqual(ExpectedOne, Res4),
    postamble().

create_bad_period_config_test() ->
    preamble(),
    Res = sysRate:create(lim1, [{period, 2000}]),
    ?assertMatch({error, {badarg, _}}, Res),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    postamble().

create_bad_config_test() ->
    preamble(),
    Res = sysRate:create(lim1, [{typeX, prio}]),
    ?assertMatch({error, {badarg, _}}, Res),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    postamble().

update_bad_config_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 200}]),
    ?assertEqual(true, sysRate:is_limiter_running(lim1)),
    Res = sysRate:set_period(lim1, 2000),
    ?assertMatch({error, {badarg, _}}, Res),
    ?assertEqual(true, sysRate:is_limiter_running(lim1)),
    postamble().

real_timer_leak_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 2}, {period, 100}]),
    Res1 = do_n_requests(lim1, 5),
    Ok1 = ok_count(Res1),
    %% Since the timer runs and leaks we could have 2 or 3 allowed
    ?assertEqual(true, (Ok1 == 2) orelse (Ok1 == 3)),
    timer:sleep(600),
    Res2 = do_n_requests(lim1, 5),
    Ok2 = ok_count(Res2),
    %% Since the timer runs and leaks we could have 2 or 3 allowed
    ?assertEqual(true, (Ok2 == 1) orelse (Ok2 == 2)),
    postamble().
    

%%------------------
%% Prio queue cases

prio_create_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 1}, manual_tick, {period, 200},
                          {type, prio}]),
    
    ?assertEqual(true, sysRate:is_limiter_running(lim1)),
    
    postamble().

prio_trumps_normal_test() ->
    preamble(),
    sysRate:create(lim1, [{rate, 10}, manual_tick, {period, 400}]),
    ExpectedRate = mk_expected(15, 10),
    ExpectedTen = mk_expected(10, 5),

    Res1 = do_n_requests(lim1, 15),
    ?assertEqual(ExpectedRate, Res1),
    ResPrio1 = do_n_requests_prio(lim1, 10, 2),
    ?assertEqual(ExpectedTen, ResPrio1),
    
    postamble().

calc_limits_20_test() ->
    Res = sysRate:calc_limits(20),
    ?assertEqual({20, 30, 32, 34, 36, 38, 40}, Res).

calc_limits_100_test() ->
    Res = sysRate:calc_limits(100),
    ?assertEqual({100, 150, 160, 170, 180, 190, 200}, Res).

mk_expected(Tot, NumExpected) ->
    Good = lists:duplicate(NumExpected, true),
    Bad  = lists:duplicate(Tot-NumExpected, false),
    Good++Bad.
    
    

%%------------------
%% Utilities

one_decimal(X) ->
    round(X*10) / 10.
    
ok_count(L) ->
    length(lists:filter(fun(X) -> X end, flat(L))).

do_run_bucket(Lim, 0, Rate) ->
    Res = do_n_requests(Lim, 2*Rate),
    [Res];
do_run_bucket(Lim, Revs, Rate) ->
    Res = do_n_requests(Lim, 2*Rate),
    sysRate:tick(Lim),
    [Res | do_run_bucket(Lim, Revs-1, Rate)].

do_n_requests(LimiterName, N) ->
    [sysRate:is_request_allowed(LimiterName) || _ <- lists:seq(1, N)].

do_run_bucket_prio(Lim, 0, Rate) ->
    Res = do_n_requests_prio(Lim, 2*Rate, 2),
    [Res];
do_run_bucket_prio(Lim, Revs, Rate) ->
    Res = do_n_requests_prio(Lim, 2*Rate, 2),
    sysRate:tick(Lim),
    [Res | do_run_bucket_prio(Lim, Revs-1, Rate)].

do_n_requests_prio(LimiterName, N, Prio) ->
    [sysRate:is_request_allowed(LimiterName, Prio) || _ <- lists:seq(1, N)].

preamble() ->
    catch postamble(),
    sysRate:start_link().

postamble() ->
    sysRate:stop().

flat(L) -> lists:flatten(L).
    
gv(K, L) -> gv(K, L, undefined).
gv(K, L, Def) -> proplists:get_value(K, L, Def).
    
