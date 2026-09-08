local file=assert(io.open('Code/sbm_decor_topup.lua','rb'))
local source=file:read('*a'); file:close()
local tail=assert(source:match('\n\t(if not ok then\n\t\tstats%.error = tostring%(err%).-)\nend%s*$'))
local function run(stats,ok,err)
  local reads,sleeps,messages,prints=0,0,0,0
  local sbm={State={}}
  local api={
    print=function(text) assert(text:find('[OptimizationFailure]',1,true)); prints=prints+1 end,
    CreateRealTimeThread=function(fn) fn() end,
    GetLoadingScreenDialog=function() reads=reads+1; return reads<=2 and {} or nil end,
    Sleep=function(ms) assert(ms==500); sleeps=sleeps+1 end,
    CreateMessageBox=function(_,title,text)
      assert(sleeps==2,'failure notice must wait until loading closes')
      assert(title:find('failed',1,true) and text:find('not valid',1,true))
      messages=messages+1
    end,
  }
  local env=setmetatable({stats=stats,ok=ok,err=err,SuperBigMap=sbm,map={name='test'},
    Global=function(name) return api[name] end},{__index=_G})
  local result=assert(load(tail,'production decor failure report','t',env))()
  if stats.error then
    assert(result==false and #sbm.State.optimization_failures==1)
    assert(sleeps==2 and messages==1 and prints==1)
  else
    assert(result==true and sbm.State.optimization_failures==nil)
    assert(reads==0 and sleeps==0 and messages==0 and prints==0)
  end
end
run({enabled=true,target=4,placed=3},true)
run({enabled=true,target=4,placed=4},true)
run({enabled=false,placed=0},true)
run({enabled=true,placed=0},false,'native error')
run({enabled=true,placed=0,error='removal API absent'},true)
print('PASS decor failure reporting: 5 production-tail cases')
