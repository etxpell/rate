
-module(sysRate_test).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).





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
    sysRate:define(lim1, []),
    ResTrue = sysRate:is_limiter_running(lim1),
    ?assertEqual(true, ResTrue),
    postamble().

simple_rate_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick]),
    Res = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res),
    postamble().

rate_tick_once_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 500}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 5),
    ?assertEqual(Expected, Res2),
    postamble().

rate_tick_uneven_test() ->
    preamble(),
    ?assertEqual(false, sysRate:is_limiter_running(lim1)),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 300}]),
    ExpectedOne = [true, false, false],
    ExpectedNone = [false, false, false],
    
    Res1 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res1),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res2),
    sysRate:tick(lim1),
    Res3 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res3),
    sysRate:tick(lim1),
    Res4 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res4),
    sysRate:tick(lim1),
    Res5 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedNone, Res5),
    sysRate:tick(lim1),
    Res6 = do_n_requests(lim1, 3),
    ?assertEqual(ExpectedOne, Res6),

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
    sysRate:define(lim1, [{rate, Rate}, manual_tick, {period, Period}]),
    Revoultions = 20*(1+round(1000 / Period)),
    TotTime = ((Revoultions)*Period/1000),
    Ok = ok_count(tl(do_run_bucket(lim1, Revoultions, Rate))),
    ActualRate = one_decimal(Ok/(TotTime)),
    %% io:format("Revs: ~p, tot time: ~p, tot: ~p, rate: ~p~n", 
    %%           [Revoultions, TotTime, Ok, ActualRate]),
    ExpectedRate = one_decimal(Rate),
    ?assertEqual(ExpectedRate, ActualRate).


limiter_crash_restart_test() ->
    preamble(),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    exit(sysRate:limiter_pid(lim1), kill),
    timer:sleep(100),
    Res2 = do_n_requests(lim1, 5),
    ?assertEqual(Expected, Res2),
    postamble().


reconfig_rate_test() ->
    preamble(),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 500}]),
    Res1 = do_n_requests(lim1, 5),
    Expected = [true, false, false, false, false],
    ?assertEqual(Expected, Res1),
    sysRate:set_rate(lim1, 2),
    sysRate:tick(lim1),
    Res2 = do_n_requests(lim1, 5),
    Expected2 = [true, true, false, false, false],
    ?assertEqual(Expected2, Res2),
    postamble().


%% counters for allowed/rejected
counter_good_test() ->
    preamble(),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 1),
    Expected = [true],
    ?assertEqual(Expected, Res1),
    Counters = sysRate:read_counters(lim1),
    ?assertEqual({1,0}, Counters),
    postamble().

counter_reject_test() ->
    preamble(),
    sysRate:define(lim1, [{rate, 1}, manual_tick, {period, 100}]),
    Res1 = do_n_requests(lim1, 2),
    Expected = [true, false],
    ?assertEqual(Expected, Res1),
    Counters = sysRate:read_counters(lim1),
    ?assertEqual({1,1}, Counters),
    postamble().



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

preamble() ->
    sysRate:start_link().

postamble() ->
    sysRate:stop().

flat(L) -> lists:flatten(L).
    

