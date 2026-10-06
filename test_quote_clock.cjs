// Execute production MQL functions, translating scalar type declarations only.
// Terminal APIs and source-chart scanning are substituted; no broker connection.
const fs=require('fs'), vm=require('vm'), assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2]||__dirname+'/SMC_SR_MTF_Signals.mq5','utf8');
function extract(name){
  const match=new RegExp('^(?:void|bool|int|string|datetime) '+name+'\\([^{}]*?\\)\\s*\\{','m').exec(source);
  assert.ok(match,'Missing production function '+name);
  let start=source.indexOf('{',match.index),end=start+1,depth=1;
  while(depth&&end<source.length){if(source[end]==='{')depth++;else if(source[end]==='}')depth--;end++;}
  let code=source.slice(match.index,end)
    .replace(/^(void|bool|int|string|datetime) /,'function ')
    .replace(/\b(?:const\s+)?(?:bool|int|string|datetime|ulong|long)\s+/g,'let ')
    .replace(/function (\w+)\(([^)]*)\)/,(_,n,p)=>'function '+n+'('+p.replace(/let /g,'').replace(/MqlTick\s*&/g,'')+')')
    .replace(/MqlTick (\w+);/g,'let $1={};')
    .replace(/MqlRates (\w+)\[\],(\w+)\[\];/g,'let $1=[],$2=[];')
    .replace(/\(datetime\)/g,'Math.trunc').replace(/\((?:bool|ulong|long|int)\)/g,'');
  return code;
}
function context(estimated=98){
  const c={server:100,mono:1000,estimated,connected:true,quote:100,
    QuoteClockServer:0,QuoteClockLastServer:0,QuoteClockSeenMs:0,QuoteClockReady:false,LastQuoteHealth:'',
    MaxQuoteAgeSeconds:15,Busy:false,TimerPulses:0,LastGoodCycle:0,LastScannedM1:0,
    DataHealth:'STARTING',LastChartsCheck:0,ChartSetReady:false,Status:'Open PERIOD_H4',
    Latest:Array.from({length:5},()=>({valid:false})),FrameCached:[],FrameStatus:[],FrameDetail:[],
    _Symbol:'GOLD',PERIOD_M1:1,TERMINAL_CONNECTED:1,
    TimeCurrent:()=>c.server,TimeTradeServer:()=>c.estimated,GetTickCount64:()=>c.mono,
    TerminalInfoInteger:()=>c.connected,SymbolInfoTick:(_,q)=>{Object.assign(q,{time:c.quote,bid:100,ask:100.1});return true;},
    iTime:()=>60,QuoteSessionState:()=>-1,LoseSync:()=>{},ResetSetup:()=>{},Dashboard:()=>{},
    Monitor:()=>{},FastPreview:()=>{},FindCharts:()=>false,
    TS:String,IntegerToString:String,Log:()=>{}
  };
  vm.createContext(c);
  for(const n of ['QuoteClockNow','QuoteClockDetail','QuoteHealth','QuoteUsable','OnTimer'])
    if(new RegExp('^(?:void|bool|int|string|datetime) '+n+'\\(','m').test(source))vm.runInContext(extract(n),c);
  return c;
}
let passed=0,failed=0;
function test(name,fn){try{fn();passed++;console.log('PASS '+name);}catch(e){failed++;console.log('FAIL '+name+': '+e.message);}}
for(const [name,estimate] of [['behind',100],['ahead',1000]])
test('Fresh broker tick reaches chart scan when local server estimate is '+name,()=>{
  const c=context(estimate);c.OnTimer(); // Startup baseline; no server progression yet.
  c.mono=3000;c.server=114;c.quote=114;c.OnTimer();
  assert.equal(c.DataHealth,'SOURCE_MISSING'); // We reached the real chart-availability gate.
});
test('Attach with a cached unchanged quote waits for broker progress',()=>{
  const c=context();c.OnTimer();assert.equal(c.DataHealth,'WAIT_CLOCK');
  c.mono=61000;c.OnTimer();assert.equal(c.DataHealth,'WAIT_CLOCK');
});
function prime(){const c=context();c.QuoteClockNow();c.mono=2000;c.server=101;c.quote=101;assert.equal(c.QuoteClockNow(),101);return c;}
test('Quote expires even when TimeCurrent freezes with all Market Watch ticks',()=>{
  const c=prime(),q={time:101,bid:100,ask:100.1};
  c.mono=17000;assert.equal(c.QuoteUsable(q),true);
  c.mono=18000;assert.equal(c.QuoteUsable(q),false);
  assert.equal(c.QuoteHealth(true,true,c.QuoteClockNow(),101,-1),'STALE_QUOTE');
});
test('Other-symbol server updates do not freshen an old GOLD quote',()=>{
  const c=prime();c.server=125;c.mono=3000;
  assert.equal(c.QuoteUsable({time:101,bid:100,ask:100.1}),false);
});
test('A delayed post-scan observation must not revive an already stale quote',()=>{
  const c=prime();c.server=102;c.quote=102;c.mono=22000;
  assert.equal(c.QuoteClockNow(),121);
  assert.equal(c.QuoteUsable({time:102,bid:100,ask:100.1}),false);
});
test('Repeated late server observations do not move the age clock backward',()=>{
  const c=prime();c.server=102;c.mono=22000;c.QuoteClockNow();
  c.server=103;c.mono=23000;
  assert.equal(c.QuoteClockNow(),122);
  assert.equal(c.QuoteUsable({time:103,bid:100,ask:100.1}),false);
});
test('Disconnect then reconnect waits for renewed server-time progress',()=>{
  const c=prime(),q={time:101,bid:100,ask:100.1};c.connected=false;
  assert.equal(c.QuoteUsable(q),false);c.connected=true;c.mono=4000;
  assert.equal(c.QuoteUsable(q),false);c.server=102;q.time=102;
  assert.equal(c.QuoteUsable(q),true);
});
test('Server-time rollback re-arms rather than using the old clock anchor',()=>{
  const c=prime();c.server=90;c.quote=90;c.mono=3000;
  assert.equal(c.QuoteClockNow(),0);c.server=91;c.quote=91;c.mono=4000;
  assert.equal(c.QuoteUsable({time:91,bid:100,ask:100.1}),true);
});
test('Local estimated-clock changes do not change the quote age',()=>{
  const c=prime();c.mono=6000;c.estimated=-3600;assert.equal(c.QuoteClockNow(),105);
  c.estimated=999999;assert.equal(c.QuoteClockNow(),105);
});
test('Missing server time blocks instead of treating a cached quote as fresh',()=>{
  const c=context();c.server=0;
  assert.equal(c.QuoteUsable({time:100,bid:100,ask:100.1}),false);
});
test('A quote genuinely ahead of received broker time remains blocked',()=>{
  const c=prime();assert.equal(c.QuoteUsable({time:110,bid:100,ask:100.1}),false);
  assert.equal(c.QuoteHealth(true,true,c.QuoteClockNow(),110,-1),'CLOCK_ERROR');
});
console.log('RESULT '+passed+' passed, '+failed+' failed');
process.exitCode=failed?1:0;
