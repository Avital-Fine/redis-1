foreach is_eval {0 1} {

if {$is_eval == 1} {
    proc run_script {args} {
        r eval {*}$args
    }
    proc run_script_ro {args} {
        r eval_ro {*}$args
    }
    proc run_script_on_connection {args} {
        [lindex $args 0] eval {*}[lrange $args 1 end]
    }
    proc kill_script {args} {
        r script kill
    }
} else {
    proc run_script {args} {
        r function load LUA test replace [format "redis.register_function('test', function(KEYS, ARGV)\n %s \nend)" [lindex $args 0]]
        r fcall test {*}[lrange $args 1 end]
    }
    proc run_script_ro {args} {
        r function load LUA test replace [format "redis.register_function{function_name='test', callback=function(KEYS, ARGV)\n %s \nend, flags={'no-writes'}}" [lindex $args 0]]
        r fcall_ro test {*}[lrange $args 1 end]
    }
    proc run_script_on_connection {args} {
        set rd [lindex $args 0]
        $rd function load LUA test replace [format "redis.register_function('test', function(KEYS, ARGV)\n %s \nend)" [lindex $args 1]]
        # read the ok reply of function create
        $rd read
        $rd fcall test {*}[lrange $args 2 end]
    }
    proc kill_script {args} {
        r function kill
    }
}

start_server {tags {"scripting"}} {

    if {$is_eval eq 1} {
    test {Script - disallow write on OOM} {
        r config set maxmemory 1

        catch {[r eval "redis.call('set', 'x', 1)" 0]} e
        assert_match {*command not allowed when used memory*} $e

        r config set maxmemory 0
    }
    } ;# is_eval

    test {EVAL - Does Lua interpreter replies to our requests?} {
        run_script {return 'hello'} 0
    } {hello}

    test {EVAL - Lua integer -> Redis protocol type conversion} {
        run_script {return 100.5} 0
    } {100}

    test {EVAL - Lua string -> Redis protocol type conversion} {
        run_script {return 'hello world'} 0
    } {hello world}

    test {EVAL - Lua true boolean -> Redis protocol type conversion} {
        run_script {return true} 0
    } {1}

    test {EVAL - Lua false boolean -> Redis protocol type conversion} {
        run_script {return false} 0
    } {}

    test {EVAL - Lua status code reply -> Redis protocol type conversion} {
        run_script {return {ok='fine'}} 0
    } {fine}

    test {EVAL - Lua error reply -> Redis protocol type conversion} {
        catch {
            run_script {return {err='this is an error'}} 0
        } e
        set _ $e
    } {this is an error}

    test {EVAL - Lua table -> Redis protocol type conversion} {
        run_script {return {1,2,3,'ciao',{1,2}}} 0
    } {1 2 3 ciao {1 2}}

    test {EVAL - Are the KEYS and ARGV arrays populated correctly?} {
        run_script {return {KEYS[1],KEYS[2],ARGV[1],ARGV[2]}} 2 a{t} b{t} c{t} d{t}
    } {a{t} b{t} c{t} d{t}}

    test {EVAL - is Lua able to call Redis API?} {
        r set mykey myval
        run_script {return redis.call('get',KEYS[1])} 1 mykey
    } {myval}

    if {$is_eval eq 1} {
    # eval sha is only relevant for is_eval Lua
    test {EVALSHA - Can we call a SHA1 if already defined?} {
        r evalsha fd758d1589d044dd850a6f05d52f2eefd27f033f 1 mykey
    } {myval}

    test {EVALSHA - Can we call a SHA1 in uppercase?} {
        r evalsha FD758D1589D044DD850A6F05D52F2EEFD27F033F 1 mykey
    } {myval}

    test {EVALSHA - Do we get an error on invalid SHA1?} {
        catch {r evalsha NotValidShaSUM 0} e
        set _ $e
    } {NOSCRIPT*}

    test {EVALSHA - Do we get an error on non defined SHA1?} {
        catch {r evalsha ffd632c7d33e571e9f24556ebed26c3479a87130 0} e
        set _ $e
    } {NOSCRIPT*}
    } ;# is_eval

    test {EVAL - Redis integer -> Lua type conversion} {
        r set x 0
        run_script {
            local foo = redis.pcall('incr',KEYS[1])
            return {type(foo),foo}
        } 1 x
    } {number 1}

    test {EVAL - Redis bulk -> Lua type conversion} {
        r set mykey myval
        run_script {
            local foo = redis.pcall('get',KEYS[1])
            return {type(foo),foo}
        } 1 mykey
    } {string myval}

    test {EVAL - Redis multi bulk -> Lua type conversion} {
        r del mylist
        r rpush mylist a
        r rpush mylist b
        r rpush mylist c
        run_script {
            local foo = redis.pcall('lrange',KEYS[1],0,-1)
            return {type(foo),foo[1],foo[2],foo[3],# foo}
        } 1 mylist
    } {table a b c 3}

    test {EVAL - Redis status reply -> Lua type conversion} {
        run_script {
            local foo = redis.pcall('set',KEYS[1],'myval')
            return {type(foo),foo['ok']}
        } 1 mykey
    } {table OK}

    test {EVAL - Redis error reply -> Lua type conversion} {
        r set mykey myval
        run_script {
            local foo = redis.pcall('incr',KEYS[1])
            return {type(foo),foo['err']}
        } 1 mykey
    } {table {ERR value is not an integer or out of range}}

    test {EVAL - Redis nil bulk reply -> Lua type conversion} {
        r del mykey
        run_script {
            local foo = redis.pcall('get',KEYS[1])
            return {type(foo),foo == false}
        } 1 mykey
    } {boolean 1}

    test {EVAL - Is the Lua client using the currently selected DB?} {
        r set mykey "this is DB 9"
        r select 10
        r set mykey "this is DB 10"
        run_script {return redis.pcall('get',KEYS[1])} 1 mykey
    } {this is DB 10} {singledb:skip}

    test {EVAL - SELECT inside Lua should not affect the caller} {
        # here we DB 10 is selected
        r set mykey "original value"
        run_script {return redis.pcall('select','9')} 0
        set res [r get mykey]
        r select 9
        set res
    } {original value} {singledb:skip}

    if 0 {
        test {EVAL - Script can't run more than configured time limit} {
            r config set lua-time-limit 1
            catch {
                run_script {
                    local i = 0
                    while true do i=i+1 end
                } 0
            } e
            set _ $e
        } {*execution time*}
    }

    test {EVAL - Scripts can't run blpop command} {
        set e {}
        catch {run_script {return redis.pcall('blpop','x',0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run brpop command} {
        set e {}
        catch {run_script {return redis.pcall('brpop','empty_list',0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run brpoplpush command} {
        set e {}
        catch {run_script {return redis.pcall('brpoplpush','empty_list1', 'empty_list2',0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run blmove command} {
        set e {}
        catch {run_script {return redis.pcall('blmove','empty_list1', 'empty_list2', 'LEFT', 'LEFT', 0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run bzpopmin command} {
        set e {}
        catch {run_script {return redis.pcall('bzpopmin','empty_zset', 0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run bzpopmax command} {
        set e {}
        catch {run_script {return redis.pcall('bzpopmax','empty_zset', 0)} 0} e
        set e
    } {*not allowed*}

    test {EVAL - Scripts can't run XREAD and XREADGROUP with BLOCK option} {
        r del s
        r xgroup create s g $ MKSTREAM
        set res [run_script {return redis.pcall('xread','STREAMS','s','$')} 1 s]
        assert {$res eq {}}
        assert_error "*xread command is not allowed with BLOCK option from scripts" {run_script {return redis.pcall('xread','BLOCK',0,'STREAMS','s','$')} 1 s}
        set res [run_script {return redis.pcall('xreadgroup','group','g','c','STREAMS','s','>')} 1 s]
        assert {$res eq {}}
        assert_error "*xreadgroup command is not allowed with BLOCK option from scripts" {run_script {return redis.pcall('xreadgroup','group','g','c','BLOCK',0,'STREAMS','s','>')} 1 s}
    }

    test {EVAL - Scripts can run non-deterministic commands} {
        set e {}
        catch {
            run_script "redis.pcall('randomkey'); return redis.pcall('set','x','ciao')" 0
        } e
        set e
    } {*OK*}

    test {EVAL - No arguments to redis.call/pcall is considered an error} {
        set e {}
        catch {run_script {return redis.call()} 0} e
        set e
    } {*one argument*}

    test {EVAL - redis.call variant raises a Lua error on Redis cmd error (1)} {
        set e {}
        catch {
            run_script "redis.call('nosuchcommand')" 0
        } e
        set e
    } {*Unknown Redis*}

    test {EVAL - redis.call variant raises a Lua error on Redis cmd error (1)} {
        set e {}
        catch {
            run_script "redis.call('get','a','b','c')" 0
        } e
        set e
    } {*number of args*}

    test {EVAL - redis.call variant raises a Lua error on Redis cmd error (1)} {
        set e {}
        r set foo bar
        catch {
            run_script {redis.call('lpush',KEYS[1],'val')} 1 foo
        } e
        set e
    } {*against a key*}

    test {EVAL - JSON numeric decoding} {
        # We must return the table as a string because otherwise
        # Redis converts floats to ints and we get 0 and 1023 instead
        # of 0.0003 and 1023.2 as the parsed output.
        run_script {return
                 table.concat(
                   cjson.decode(
                    "[0.0, -5e3, -1, 0.3e-3, 1023.2, 0e10]"), " ")
        } 0
    } {0 -5000 -1 0.0003 1023.2 0}

    test {EVAL - JSON string decoding} {
        run_script {local decoded = cjson.decode('{"keya": "a", "keyb": "b"}')
                return {decoded.keya, decoded.keyb}
        } 0
    } {a b}

    test {EVAL - cmsgpack can pack double?} {
        run_script {local encoded = cmsgpack.pack(0.1)
                local h = ""
                for i = 1, #encoded do
                    h = h .. string.format("%02x",string.byte(encoded,i))
                end
                return h
        } 0
    } {cb3fb999999999999a}

    test {EVAL - cmsgpack can pack negative int64?} {
        run_script {local encoded = cmsgpack.pack(-1099511627776)
                local h = ""
                for i = 1, #encoded do
                    h = h .. string.format("%02x",string.byte(encoded,i))
                end
                return h
        } 0
    } {d3ffffff0000000000}

    test {EVAL - cmsgpack can pack and unpack circular references?} {
        run_script {local a = {x=nil,y=5}
                local b = {x=a}
                a['x'] = b
                local encoded = cmsgpack.pack(a)
                local h = ""
                -- cmsgpack encodes to a depth of 16, but can't encode
                -- references, so the encoded object has a deep copy recursive
                -- depth of 16.
                for i = 1, #encoded do
                    h = h .. string.format("%02x",string.byte(encoded,i))
                end
                -- when unpacked, re.x.x != re because the unpack creates
                -- individual tables down to a depth of 16.
                -- (that's why the encoded output is so large)
                local re = cmsgpack.unpack(encoded)
                assert(re)
                assert(re.x)
                assert(re.x.x.y == re.y)
                assert(re.x.x.x.x.y == re.y)
                assert(re.x.x.x.x.x.x.y == re.y)
                assert(re.x.x.x.x.x.x.x.x.x.x.y == re.y)
                -- maximum working depth:
                assert(re.x.x.x.x.x.x.x.x.x.x.x.x.x.x.y == re.y)
                -- now the last x would be b above and has no y
                assert(re.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x)
                -- so, the final x.x is at the depth limit and was assigned nil
                assert(re.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x.x == nil)
                return {h, re.x.x.x.x.x.x.x.x.y == re.y, re.y == 5}
        } 0
    } {82a17905a17881a17882a17905a17881a17882a17905a17881a17882a17905a17881a17882a17905a17881a17882a17905a17881a17882a17905a17881a17882a17905a17881a178c0 1 1}

    test {EVAL - Numerical sanity check from bitop} {
        run_script {assert(0x7fffffff == 2147483647, "broken hex literals");
                assert(0xffffffff == -1 or 0xffffffff == 2^32-1,
                    "broken hex literals");
                assert(tostring(-1) == "-1", "broken tostring()");
                assert(tostring(0xffffffff) == "-1" or
                    tostring(0xffffffff) == "4294967295",
                    "broken tostring()")
        } 0
    } {}

    test {EVAL - Verify minimal bitop functionality} {
        run_script {assert(bit.tobit(1) == 1);
                assert(bit.band(1) == 1);
                assert(bit.bxor(1,2) == 3);
                assert(bit.bor(1,2,4,8,16,32,64,128) == 255)
        } 0
    } {}

    test {EVAL - Able to parse trailing comments} {
        run_script {return 'hello' --trailing comment} 0
    } {hello}

    test {EVAL_RO - Successful case} {
        r set foo bar
        assert_equal bar [run_script_ro {return redis.call('get', KEYS[1]);} 1 foo]
    }

    test {EVAL_RO - Cannot run write commands} {
        r set foo bar
        catch {run_script_ro {redis.call('del', KEYS[1]);} 1 foo} e
        set e
    } {*Write commands are not allowed from read-only scripts*}

    if {$is_eval eq 1} {
    # script command is only relevant for is_eval Lua
    test {SCRIPTING FLUSH - is able to clear the scripts cache?} {
        r set mykey myval
        set v [r evalsha fd758d1589d044dd850a6f05d52f2eefd27f033f 1 mykey]
        assert_equal $v myval
        set e ""
        r script flush
        catch {r evalsha fd758d1589d044dd850a6f05d52f2eefd27f033f 1 mykey} e
        set e
    } {NOSCRIPT*}

    test {SCRIPTING FLUSH ASYNC} {
        for {set j 0} {$j < 100} {incr j} {
            r script load "return $j"
        }
        assert { [string match "*number_of_cached_scripts:100*" [r info Memory]] }
        r script flush async
        assert { [string match "*number_of_cached_scripts:0*" [r info Memory]] }
    }

    test {SCRIPT EXISTS - can detect already defined scripts?} {
        r eval "return 1+1" 0
        r script exists a27e7e8a43702b7046d4f6a7ccf5b60cef6b9bd9 a27e7e8a43702b7046d4f6a7ccf5b60cef6b9bda
    } {1 0}

    test {SCRIPT LOAD - is able to register scripts in the scripting cache} {
        list \
            [r script load "return 'loaded'"] \
            [r evalsha b534286061d4b9e4026607613b95c06c06015ae8 0]
    } {b534286061d4b9e4026607613b95c06c06015ae8 loaded}

    test "SORT is normally not alpha re-ordered for the scripting engine" {
        r del myset
        r sadd myset 1 2 3 4 10
        r eval {return redis.call('sort',KEYS[1],'desc')} 1 myset
    } {10 4 3 2 1} {cluster:skip}

    test "SORT BY <constant> output gets ordered for scripting" {
        r del myset
        r sadd myset a b c d e f g h i l m n o p q r s t u v z aa aaa azz
        r eval {return redis.call('sort',KEYS[1],'by','_')} 1 myset
    } {a aa aaa azz b c d e f g h i l m n o p q r s t u v z} {cluster:skip}

    test "SORT BY <constant> with GET gets ordered for scripting" {
        r del myset
        r sadd myset a b c
        r eval {return redis.call('sort',KEYS[1],'by','_','get','#','get','_:*')} 1 myset
    } {a {} b {} c {}} {cluster:skip}
    } ;# is_eval

    test "redis.sha1hex() implementation" {
        list [run_script {return redis.sha1hex('')} 0] \
             [run_script {return redis.sha1hex('Pizza & Mandolino')} 0]
    } {da39a3ee5e6b4b0d3255bfef95601890afd80709 74822d82031af7493c20eefa13bd07ec4fada82f}

    test {Globals protection reading an undeclared global variable} {
        catch {run_script {return a} 0} e
        set e
    } {*ERR*attempted to access * global*}

    test {Globals protection setting an undeclared global*} {
        catch {run_script {a=10} 0} e
        set e
    } {*ERR*attempted to create global*}

    test {Test an example script DECR_IF_GT} {
        set decr_if_gt {
            local current

            current = redis.call('get',KEYS[1])
            if not current then return nil end
            if current > ARGV[1] then
                return redis.call('decr',KEYS[1])
            else
                return redis.call('get',KEYS[1])
            end
        }
        r set foo 5
        set res {}
        lappend res [run_script $decr_if_gt 1 foo 2]
        lappend res [run_script $decr_if_gt 1 foo 2]
        lappend res [run_script $decr_if_gt 1 foo 2]
        lappend res [run_script $decr_if_gt 1 foo 2]
        lappend res [run_script $decr_if_gt 1 foo 2]
        set res
    } {4 3 2 2 2}

    if {$is_eval eq 1} {
    # random handling is only relevant for is_eval Lua
    test {random numbers are random now} {
        set rand1 [r eval {return tostring(math.random())} 0]
        wait_for_condition 100 1 {
            $rand1 ne [r eval {return tostring(math.random())} 0]
        } else {
            fail "random numbers should be random, now it's fixed value"
        }
    }

    test {Scripting engine PRNG can be seeded correctly} {
        set rand1 [r eval {
            math.randomseed(ARGV[1]); return tostring(math.random())
        } 0 10]
        set rand2 [r eval {
            math.randomseed(ARGV[1]); return tostring(math.random())
        } 0 10]
        set rand3 [r eval {
            math.randomseed(ARGV[1]); return tostring(math.random())
        } 0 20]
        assert_equal $rand1 $rand2
        assert {$rand2 ne $rand3}
    }
    } ;# is_eval

    test {EVAL does not leak in the Lua stack} {
        r set x 0
        # Use a non blocking client to speedup the loop.
        set rd [redis_deferring_client]
        for {set j 0} {$j < 10000} {incr j} {
            run_script_on_connection $rd {return redis.call("incr",KEYS[1])} 1 x
        }
        for {set j 0} {$j < 10000} {incr j} {
            $rd read
        }
        assert {[s used_memory_lua] < 1024*100}
        $rd close
        r get x
    } {10000}

    if {$is_eval eq 1} {
    test {SPOP: We can call scripts rewriting client->argv from Lua} {
        set repl [attach_to_replication_stream]
        #this sadd operation is for external-cluster test. If myset doesn't exist, 'del myset' won't get propagated.
        r sadd myset ppp
        r del myset
        r sadd myset a b c
        assert {[r eval {return redis.call('spop', 'myset')} 0] ne {}}
        assert {[r eval {return redis.call('spop', 'myset', 1)} 0] ne {}}
        assert {[r eval {return redis.call('spop', KEYS[1])} 1 myset] ne {}}
        # this one below should not be replicated
        assert {[r eval {return redis.call('spop', KEYS[1])} 1 myset] eq {}}
        r set trailingkey 1
        assert_replication_stream $repl {
            {select *}
            {sadd *}
            {del *}
            {sadd *}
            {srem myset *}
            {srem myset *}
            {srem myset *}
            {set *}
        }
        close_replication_stream $repl
    } {} {needs:repl}

    test {MGET: mget shouldn't be propagated in Lua} {
        set repl [attach_to_replication_stream]
        r mset a{t} 1 b{t} 2 c{t} 3 d{t} 4
        #read-only, won't be replicated
        assert {[r eval {return redis.call('mget', 'a{t}', 'b{t}', 'c{t}', 'd{t}')} 0] eq {1 2 3 4}}
        r set trailingkey 2
        assert_replication_stream $repl {
            {select *}
            {mset *}
            {set *}
        }
        close_replication_stream $repl
    } {} {needs:repl}

    test {EXPIRE: We can call scripts rewriting client->argv from Lua} {
        set repl [attach_to_replication_stream]
        r set expirekey 1
        #should be replicated as EXPIREAT
        assert {[r eval {return redis.call('expire', KEYS[1], ARGV[1])} 1 expirekey 3] eq 1}

        assert_replication_stream $repl {
            {select *}
            {set *}
            {pexpireat expirekey *}
        }
        close_replication_stream $repl
    } {} {needs:repl}

    } ;# is_eval

    test {Call Redis command with many args from Lua (issue #1764)} {
        run_script {
            local i
            local x={}
            redis.call('del','mylist')
            for i=1,100 do
                table.insert(x,i)
            end
            redis.call('rpush','mylist',unpack(x))
            return redis.call('lrange','mylist',0,-1)
        } 1 mylist
    } {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 97 98 99 100}

    test {Number conversion precision test (issue #1118)} {
        run_script {
              local value = 9007199254740991
              redis.call("set","foo",value)
              return redis.call("get","foo")
        } 1 foo
    } {9007199254740991}

    test {String containing number precision test (regression of issue #1118)} {
        run_script {
            redis.call("set", "key", "12039611435714932082")
            return redis.call("get", "key")
        } 1 key
    } {12039611435714932082}

    test {Verify negative arg count is error instead of crash (issue #1842)} {
        catch { run_script { return "hello" } -12 } e
        set e
    } {ERR Number of keys can't be negative}

    test {Scripts can handle commands with incorrect arity} {
        assert_error "*Wrong number of args calling Redis command from script" {run_script "redis.call('set','invalid')" 0}
        assert_error "*Wrong number of args calling Redis command from script" {run_script "redis.call('incr')" 0}
    }

    test {Correct handling of reused argv (issue #1939)} {
        run_script {
              for i = 0, 10 do
                  redis.call('SET', 'a{t}', '1')
                  redis.call('MGET', 'a{t}', 'b{t}', 'c{t}')
                  redis.call('EXPIRE', 'a{t}', 0)
                  redis.call('GET', 'a{t}')
                  redis.call('MGET', 'a{t}', 'b{t}', 'c{t}')
              end
        } 3 a{t} b{t} c{t}
    }

    test {Functions in the Redis namespace are able to report errors} {
        catch {
            run_script {
                  redis.sha1hex()
            } 0
        } e
        set e
    } {*wrong number*}

    test {CLUSTER RESET can not be invoke from within a script} {
        catch {
            run_script {
                  redis.call('cluster', 'reset', 'hard')
            } 0
        } e
        set _ $e
    } {*command is not allowed*}

    test {Script with RESP3 map} {
        set expected_dict [dict create field value]
        set expected_list [list field value]

        # Sanity test for RESP3 without scripts
        r HELLO 3
        r hset hash field value
        set res [r hgetall hash]
        assert_equal $res $expected_dict

        # Test RESP3 client with script in both RESP2 and RESP3 modes
        set res [run_script {redis.setresp(3); return redis.call('hgetall', KEYS[1])} 1 hash]
        assert_equal $res $expected_dict
        set res [run_script {redis.setresp(2); return redis.call('hgetall', KEYS[1])} 1 hash]
        assert_equal $res $expected_list

        # Test RESP2 client with script in both RESP2 and RESP3 modes
        r HELLO 2
        set res [run_script {redis.setresp(3); return redis.call('hgetall', KEYS[1])} 1 hash]
        assert_equal $res $expected_list
        set res [run_script {redis.setresp(2); return redis.call('hgetall', KEYS[1])} 1 hash]
        assert_equal $res $expected_list
    }

    test {Script return recursive object} {
        r readraw 1
        set res [run_script {local a = {}; local b = {a}; a[1] = b; return a} 0]
        # drain the response
        while {true} {
            if {$res == "-ERR reached lua stack limit"} {
                break
            }
            assert_equal $res "*1"
            set res [r read]
        }
        r readraw 0
        # make sure the connection is still valid
        assert_equal [r ping] {PONG}
    }

    test {Script check unpack with massive arguments} {
        run_script {
            local a = {}
            for i=1,7999 do
                a[i] = 1
            end
            return redis.call("lpush", "l", unpack(a))
        } 0
    } {7999}

    test "Script read key with expiration set" {
        r SET key value EX 10
        assert_equal [run_script {
             if redis.call("EXISTS", "key") then
                 return redis.call("GET", "key")
             else
                 return redis.call("EXISTS", "key")
             end
        } 0] "value"
    }

    test "Script del key with expiration set" {
        r SET key value EX 10
        assert_equal [run_script {
             redis.call("DEL", "key")
             return redis.call("EXISTS", "key")
        } 0] 0
    }
    
    test "Script ACL check" {
        r acl setuser bob on {>123} {+@scripting} {+set} {~x*}
        assert_equal [r auth bob 123] {OK}
        
        # Check permission granted
        assert_equal [run_script {
            return redis.acl_check_cmd('set','xx',1)
        } 1 xx] 1

        # Check permission denied unauthorised command
        assert_equal [run_script {
            return redis.acl_check_cmd('hset','xx','f',1)
        } 1 xx] {}
        
        # Check permission denied unauthorised key
        # Note: we don't pass the "yy" key as an argument to the script so key acl checks won't block the script
        assert_equal [run_script {
            return redis.acl_check_cmd('set','yy',1)
        } 0] {}

        # Check error due to invalid command
        assert_error {ERR *Invalid command passed to redis.acl_check_cmd()} {run_script {
            return redis.acl_check_cmd('invalid-cmd','arg')
        } 0}
    }
}

# Start a new server since the last test in this stanza will kill the
# instance at all.
start_server {tags {"scripting"}} {
    test {Timedout read-only scripts can be killed by SCRIPT KILL} {
        set rd [redis_deferring_client]
        r config set lua-time-limit 10
        run_script_on_connection $rd {while true do end} 0
        after 200
        catch {r ping} e
        assert_match {BUSY*} $e
        kill_script
        after 200 ; # Give some time to Lua to call the hook again...
        assert_equal [r ping] "PONG"
        $rd close
    }

    test {Timedout read-only scripts can be killed by SCRIPT KILL even when use pcall} {
        set rd [redis_deferring_client]
        r config set lua-time-limit 10
        run_script_on_connection $rd {local f = function() while 1 do redis.call('ping') end end while 1 do pcall(f) end} 0

        wait_for_condition 50 100 {
            [catch {r ping} e] == 1
        } else {
            fail "Can't wait for script to start running"
        }
        catch {r ping} e
        assert_match {BUSY*} $e

        kill_script

        wait_for_condition 50 100 {
            [catch {r ping} e] == 0
        } else {
            fail "Can't wait for script to be killed"
        }
        assert_equal [r ping] "PONG"

        catch {$rd read} res
        $rd close

        assert_match {*killed by user*} $res
    }

    test {Timedout script does not cause a false dead client} {
        set rd [redis_deferring_client]
        r config set lua-time-limit 10

        # senging (in a pipeline):
        # 1. eval "while 1 do redis.call('ping') end" 0
        # 2. ping
        if {$is_eval == 1} {
            set buf "*3\r\n\$4\r\neval\r\n\$33\r\nwhile 1 do redis.call('ping') end\r\n\$1\r\n0\r\n"
            append buf "*1\r\n\$4\r\nping\r\n"
        } else {
            set buf "*6\r\n\$8\r\nfunction\r\n\$4\r\nload\r\n\$3\r\nlua\r\n\$4\r\ntest\r\n\$7\r\nreplace\r\n\$81\r\nredis.register_function('test', function() while 1 do redis.call('ping') end end)\r\n"
            append buf "*3\r\n\$5\r\nfcall\r\n\$4\r\ntest\r\n\$1\r\n0\r\n"
            append buf "*1\r\n\$4\r\nping\r\n"
        }
        $rd write $buf
        $rd flush

        wait_for_condition 50 100 {
            [catch {r ping} e] == 1
        } else {
            fail "Can't wait for script to start running"
        }
        catch {r ping} e
        assert_match {BUSY*} $e

        kill_script
        wait_for_condition 50 100 {
            [catch {r ping} e] == 0
        } else {
            fail "Can't wait for script to be killed"
        }
        assert_equal [r ping] "PONG"

        if {$is_eval == 0} {
            # read the ok reply of function create
            assert_match {OK} [$rd read]
        }

        catch {$rd read} res
        assert_match {*killed by user*} $res

        set res [$rd read]
        assert_match {*PONG*} $res

        $rd close
    }

    test {Timedout script link is still usable after Lua returns} {
        r config set lua-time-limit 10
        run_script {for i=1,100000 do redis.call('ping') end return 'ok'} 0
        r ping
    } {PONG}

    test {Timedout scripts that modified data can't be killed by SCRIPT KILL} {
        set rd [redis_deferring_client]
        r config set lua-time-limit 10
        run_script_on_connection $rd {redis.call('set',KEYS[1],'y'); while true do end} 1 x
        after 200
        catch {r ping} e
        assert_match {BUSY*} $e
        catch {kill_script} e
        assert_match {UNKILLABLE*} $e
        catch {r ping} e
        assert_match {BUSY*} $e
    } {} {external:skip}

    # Note: keep this test at the end of this server stanza because it
    # kills the server.
    test {SHUTDOWN NOSAVE can kill a timedout script anyway} {
        # The server should be still unresponding to normal commands.
        catch {r ping} e
        assert_match {BUSY*} $e
        catch {r shutdown nosave}
        # Make sure the server was killed
        catch {set rd [redis_deferring_client]} e
        assert_match {*connection refused*} $e
    } {} {external:skip}
}

    start_server {tags {"scripting repl needs:debug external:skip"}} {
        start_server {} {
            test "Before the replica connects we issue two EVAL commands" {
                # One with an error, but still executing a command.
                # SHA is: 67164fc43fa971f76fd1aaeeaf60c1c178d25876
                catch {
                    run_script {redis.call('incr',KEYS[1]); redis.call('nonexisting')} 1 x
                }
                # One command is correct:
                # SHA is: 6f5ade10a69975e903c6d07b10ea44c6382381a5
                run_script {return redis.call('incr',KEYS[1])} 1 x
            } {2}

            test "Connect a replica to the master instance" {
                r -1 slaveof [srv 0 host] [srv 0 port]
                wait_for_condition 50 100 {
                    [s -1 role] eq {slave} &&
                    [string match {*master_link_status:up*} [r -1 info replication]]
                } else {
                    fail "Can't turn the instance into a replica"
                }
            }

            if {$is_eval eq 1} {
            test "Now use EVALSHA against the master, with both SHAs" {
                # The server should replicate successful and unsuccessful
                # commands as EVAL instead of EVALSHA.
                catch {
                    r evalsha 67164fc43fa971f76fd1aaeeaf60c1c178d25876 1 x
                }
                r evalsha 6f5ade10a69975e903c6d07b10ea44c6382381a5 1 x
            } {4}

            test "'x' should be '4' for EVALSHA being replicated by effects" {
                wait_for_condition 50 100 {
                    [r -1 get x] eq {4}
                } else {
                    fail "Expected 4 in x, but value is '[r -1 get x]'"
                }
            }
            } ;# is_eval

            test "Replication of script multiple pushes to list with BLPOP" {
                set rd [redis_deferring_client]
                $rd brpop a 0
                run_script {
                    redis.call("lpush",KEYS[1],"1");
                    redis.call("lpush",KEYS[1],"2");
                } 1 a
                set res [$rd read]
                $rd close
                wait_for_condition 50 100 {
                    [r -1 lrange a 0 -1] eq [r lrange a 0 -1]
                } else {
                    fail "Expected list 'a' in replica and master to be the same, but they are respectively '[r -1 lrange a 0 -1]' and '[r lrange a 0 -1]'"
                }
                set res
            } {a 1}

            if {$is_eval eq 1} {
            test "EVALSHA replication when first call is readonly" {
                r del x
                r eval {if tonumber(ARGV[1]) > 0 then redis.call('incr', KEYS[1]) end} 1 x 0
                r evalsha 6e0e2745aa546d0b50b801a20983b70710aef3ce 1 x 0
                r evalsha 6e0e2745aa546d0b50b801a20983b70710aef3ce 1 x 1
                wait_for_condition 50 100 {
                    [r -1 get x] eq {1}
                } else {
                    fail "Expected 1 in x, but value is '[r -1 get x]'"
                }
            }
            } ;# is_eval

            test "Lua scripts using SELECT are replicated correctly" {
                run_script {
                    redis.call("set","foo1","bar1")
                    redis.call("select","10")
                    redis.call("incr","x")
                    redis.call("select","11")
                    redis.call("incr","z")
                } 0
                run_script {
                    redis.call("set","foo1","bar1")
                    redis.call("select","10")
                    redis.call("incr","x")
                    redis.call("select","11")
                    redis.call("incr","z")
                } 0
                wait_for_condition 50 100 {
                    [debug_digest -1] eq [debug_digest]
                } else {
                    fail "Master-Replica desync after Lua script using SELECT."
                }
            } {} {singledb:skip}
        }
    }

start_server {tags {"scripting repl external:skip"}} {
    start_server {overrides {appendonly yes aof-use-rdb-preamble no}} {
        test "Connect a replica to the master instance" {
            r -1 slaveof [srv 0 host] [srv 0 port]
            wait_for_condition 50 100 {
                [s -1 role] eq {slave} &&
                [string match {*master_link_status:up*} [r -1 info replication]]
            } else {
                fail "Can't turn the instance into a replica"
            }
        }

        # replicate_commands is the default on Redis Function
        test "Redis.replicate_commands() can be issued anywhere now" {
            r eval {
                redis.call('set','foo','bar');
                return redis.replicate_commands();
            } 0
        } {1}

        test "Redis.set_repl() can be issued before replicate_commands() now" {
            catch {
                r eval {
                    redis.set_repl(redis.REPL_ALL);
                } 0
            } e
            set e
        } {}

        test "Redis.set_repl() don't accept invalid values" {
            catch {
                run_script {
                    redis.set_repl(12345);
                } 0
            } e
            set e
        } {*Invalid*flags*}

        test "Test selective replication of certain Redis commands from Lua" {
            r del a b c d
            run_script {
                redis.call('set','a','1');
                redis.set_repl(redis.REPL_NONE);
                redis.call('set','b','2');
                redis.set_repl(redis.REPL_AOF);
                redis.call('set','c','3');
                redis.set_repl(redis.REPL_ALL);
                redis.call('set','d','4');
            } 0

            wait_for_condition 50 100 {
                [r -1 mget a b c d] eq {1 {} {} 4}
            } else {
                fail "Only a and d should be replicated to replica"
            }

            # Master should have everything right now
            assert {[r mget a b c d] eq {1 2 3 4}}

            # After an AOF reload only a, c and d should exist
            r debug loadaof

            assert {[r mget a b c d] eq {1 {} 3 4}}
        }

        test "PRNG is seeded randomly for command replication" {
            if {$is_eval eq 1} {
                # on is_eval Lua we need to call redis.replicate_commands() to get real randomization
                set a [
                    run_script {
                        redis.replicate_commands()
                        return math.random()*100000;
                    } 0
                ]
                set b [
                    run_script {
                        redis.replicate_commands()
                        return math.random()*100000;
                    } 0
                ]
            } else {
                set a [
                    run_script {
                        return math.random()*100000;
                    } 0
                ]
                set b [
                    run_script {
                        return math.random()*100000;
                    } 0
                ]
            }
            assert {$a ne $b}
        }

        test "Using side effects is not a problem with command replication" {
            run_script {
                redis.call('set','time',redis.call('time')[1])
            } 0

            assert {[r get time] ne {}}

            wait_for_condition 50 100 {
                [r get time] eq [r -1 get time]
            } else {
                fail "Time key does not match between master and replica"
            }
        }
    }
}

if {$is_eval eq 1} {
start_server {tags {"scripting external:skip"}} {
    r script debug sync
    r eval {return 'hello'} 0
    r eval {return 'hello'} 0
}

start_server {tags {"scripting needs:debug external:skip"}} {
    test {Test scripting debug protocol parsing} {
        r script debug sync
        r eval {return 'hello'} 0
        catch {r 'hello\0world'} e
        assert_match {*Unknown Redis Lua debugger command*} $e
        catch {r 'hello\0'} e
        assert_match {*Unknown Redis Lua debugger command*} $e
        catch {r '\0hello'} e
        assert_match {*Unknown Redis Lua debugger command*} $e
        catch {r '\0hello\0'} e
        assert_match {*Unknown Redis Lua debugger command*} $e
    }

    test {Test scripting debug lua stack overflow} {
        r script debug sync
        r eval {return 'hello'} 0
        set cmd "*101\r\n\$5\r\nredis\r\n"
        append cmd [string repeat "\$4\r\ntest\r\n" 100]
        r write $cmd
        r flush
        set ret [r read]
        assert_match {*Unknown Redis command called from script*} $ret
        # make sure the server is still ok
        reconnect
        assert_equal [r ping] {PONG}
    }
}
} ;# is_eval

start_server {tags {"scripting needs:debug"}} {
    r debug set-disable-deny-scripts 1

    for {set i 2} {$i <= 3} {incr i} {
        for {set client_proto 2} {$client_proto <= 3} {incr client_proto} {
            set extra "RESP$i/$client_proto"
            r hello $client_proto
            r readraw 1

            test "test $extra big number protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'bignum')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {$37}
                    assert_equal [r read] {1234567999999999999999999999999999999}
                } else {
                    assert_equal $ret {(1234567999999999999999999999999999999}
                }
            }

            test "test $extra malformed big number protocol parsing" {
                set ret [run_script "return {big_number='123\\r\\n123'}" 0]
                if {$client_proto == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {$8}
                    assert_equal [r read] {123  123}
                } else {
                    assert_equal $ret {(123  123}
                }
            }

            test "test $extra map protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'map')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {*6}
                } else {
                    assert_equal $ret {%3}
                }
                for {set j 0} {$j < 6} {incr j} {
                    r read
                }
            }

            test "test $extra set protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'set')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {*3}
                } else {
                    assert_equal $ret {~3}
                }
                for {set j 0} {$j < 3} {incr j} {
                    r read
                }
            }

            test "test $extra double protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'double')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {$5}
                    assert_equal [r read] {3.141}
                } else {
                    assert_equal $ret {,3.141}
                }
            }

            test "test $extra null protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'null')" 0]
                if {$client_proto == 2} {
                    # null is a special case in which a Lua client format does not effect the reply to the client
                    assert_equal $ret {$-1}
                } else {
                    assert_equal $ret {_}
                }
            } {}

            test "test $extra verbatim protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'verbatim')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {$25}
                    assert_equal [r read] {This is a verbatim}
                    assert_equal [r read] {string}
                } else {
                    assert_equal $ret {=29}
                    assert_equal [r read] {txt:This is a verbatim}
                    assert_equal [r read] {string}
                }
            }

            test "test $extra true protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'true')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {:1}
                } else {
                    assert_equal $ret {#t}
                }
            }

            test "test $extra false protocol parsing" {
                set ret [run_script "redis.setresp($i);return redis.call('debug', 'protocol', 'false')" 0]
                if {$client_proto == 2 || $i == 2} {
                    # if either Lua or the client is RESP2 the reply will be RESP2
                    assert_equal $ret {:0}
                } else {
                    assert_equal $ret {#f}
                }
            }

            r readraw 0
        }
    }

    # attribute is not relevant to test with resp2
    test {test resp3 attribute protocol parsing} {
        # attributes are not (yet) expose to the script
        # So here we just check the parser handles them and they are ignored.
        run_script "redis.setresp(3);return redis.call('debug', 'protocol', 'attrib')" 0
    } {Some real reply following the attribute}

    test "Script block the time during execution" {
        assert_equal [run_script {
            redis.call("SET", "key", "value", "PX", "1")
            redis.call("DEBUG", "SLEEP", 0.01)
            return redis.call("EXISTS", "key")
        } 0] 1

        assert_equal 0 [r EXISTS key]
    }

    test "Script delete the expired key" {
        r DEBUG set-active-expire 0
        r SET key value PX 1
        after 2

        # use DEBUG OBJECT to make sure it doesn't error (means the key still exists)
        r DEBUG OBJECT key

        assert_equal [run_script "return redis.call('EXISTS', 'key')" 0] 0
        assert_equal 0 [r EXISTS key]
        r DEBUG set-active-expire 1
    }

    r debug set-disable-deny-scripts 0
}
} ;# foreach is_eval


# Scripting "shebang" notation tests
start_server {tags {"scripting"}} {
    test "Shebang support for lua engine" {
        catch {
            r eval {#!not-lua
                return 1
            } 0
        } e
        assert_match {*Unexpected engine in script shebang*} $e

        assert_equal [r eval {#!lua
            return 1
        } 0] 1
    }

    test "Unknown shebang option" {
        catch {
            r eval {#!lua badger=data
                return 1
            } 0
        } e
        assert_match {*Unknown lua shebang option*} $e
    }

    test "Unknown shebang flag" {
        catch {
            r eval {#!lua flags=allow-oom,what?
                return 1
            } 0
        } e
        assert_match {*Unexpected flag in script shebang*} $e
    }

    test "allow-oom shebang flag" {
        r set x 123
    
        r config set maxmemory 1

        # Fail to execute deny-oom command in OOM condition (backwards compatibility mode without flags)
        assert_error {ERR Error running script *OOM command not allowed when used memory > 'maxmemory'.} {
            r eval {
                redis.call('set','x',1)
                return 1
            } 1 x
        }
        # Can execute non deny-oom commands in OOM condition (backwards compatibility mode without flags)
        assert_equal [
            r eval {
                return redis.call('get','x')
            } 1 x
        ] {123}

        # Fail to execute regardless of script content when we use default flags in OOM condition
        assert_error {OOM allow-oom flag is not set on the script, can not run it when used memory > 'maxmemory'} {
            r eval {#!lua flags=
                return 1
            } 0
        }

        assert_equal [
            r eval {#!lua flags=allow-oom
                redis.call('set','x',1)
                return 1
            } 0
        ] 1

        r config set maxmemory 0
    }

    test "no-writes shebang flag" {
        assert_error {ERR Error running script *Write commands are not allowed from read-only scripts.} {
            r eval {#!lua flags=no-writes
                redis.call('set','x',1)
                return 1
            } 1 x
        }
    }
    
    start_server {tags {"external:skip"}} {
        r -1 set x "some value"
        test "no-writes shebang flag on replica" {
            r replicaof [srv -1 host] [srv -1 port]
            wait_for_condition 50 100 {
                [s role] eq {slave} &&
                [string match {*master_link_status:up*} [r info replication]]
            } else {
                fail "Can't turn the instance into a replica"
            }

            assert_equal [
                r eval {#!lua flags=no-writes
                    return redis.call('get','x')
                } 1 x
            ] "some value"

            assert_error {ERR Can not run script with write flag on readonly replica} {
                r eval {#!lua
                    return redis.call('get','x')
                } 1 x
            }
        }
    }

    test "allow-stale shebang flag" {
        r config set replica-serve-stale-data no
        r replicaof 127.0.0.1 1

        assert_error {MASTERDOWN Link with MASTER is down and replica-serve-stale-data is set to 'no'.} {
            r eval {
                return redis.call('get','x')
            } 1 x
        }

        assert_error {*'allow-stale' flag is not set on the script*} {
            r eval {#!lua flags=no-writes
                return 1
            } 0
        }

        assert_equal [
            r eval {#!lua flags=allow-stale,no-writes
                return 1
            } 0
        ] 1


        assert_error {*Can not execute the command on a stale replica*} {
            r eval {#!lua flags=allow-stale,no-writes
                return redis.call('get','x')
            } 1 x
        }
        
        assert_match {*redis_version*} [
            r eval {#!lua flags=allow-stale,no-writes
                return redis.call('info','server')
            } 0
        ]
        
        # Test again with EVALSHA
        set sha [
            r script load {#!lua flags=allow-stale,no-writes
                return redis.call('info','server')
            }
        ]
        assert_match {*redis_version*} [r evalsha $sha 0]
        
        r replicaof no one
        r config set replica-serve-stale-data yes
        set _ {}
    } {} {external:skip}
}
