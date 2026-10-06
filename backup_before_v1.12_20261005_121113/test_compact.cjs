// Source-executing regression tests. Only MQL type syntax is translated;
// the Process state machine and pure presentation helpers run from the MQ5.
// MT5 I/O is substituted because Node cannot access chart objects or ticks.
const fs=require('fs'),vm=require('vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(process.argv[2]||__dirname+'/SMC_SR_MTF_Signals.mq5','utf8');
function extract(name){
  const re=new RegExp('^(?:void|bool|int|string|double) '+name+'\\([^{}]*?\\)\\s*\\{','m');
  const hit=re.exec(source);assert.ok(hit,'Missing production helper: '+name);
  let start=source.indexOf('{',hit.index),depth=1,i=start+1;
  while(depth&&i<source.length){if(source[i]==='{')depth++;else if(source[i]==='}')depth--;i++;}
  const header=source.slice(hit.index,start).replace(/^(void|bool|int|string|double) /,'function ').replace(/\b(?:const\s+)?(?:MqlRates|MqlTick|bool|int|string|double|datetime|long|color|uint)\s*[&]?\s*/g,'').replace(/\[\]/g,'');
  const body=source.slice(start,i).replace(/\b(?:double|int|string|bool|datetime|long|uint|color)\s+(?=[A-Za-z_])/g,'let ').replace(/StructureEvent e;/g,'let e={};').replace(/MqlTick q;/g,'let q={};').replace(/FastZone w=/g,'let w=').replace(/\((?:int|long)\)/g,'');
  return header+body;
}
let failures=0,passed=0;
function test(name,fn){try{fn();passed++;console.log('PASS '+name);}catch(e){failures++;console.log('FAIL '+name+': '+e.message);}}
function processContext(dir,confirmClosed,breakClosed,now=3062){
  const ctx={WAIT_ZONE:0,WAIT_M5_CHOCH:1,WAIT_M1_BREAK:2,WAIT_M1_RETEST:3,Stage:1,
    Latest:[{dir},{dir}],RequireH4Alignment:false,Active:false,NextAllowed:0,
    SetupDir:dir,StrictSetupID:'fixture',Expiry:6600,SweepClosed:2700,ConfirmName:'',ConfirmClosed:0,ConfirmPrice:0,
    BreakName:'',BreakClosed:0,BreakPrice:0,Stop:dir>0?80:120,SetupZone:{low:90,high:110},
    RetestExpiryM1Bars:10,Retest_ATR_Tolerance:.1,TickSize:.01,
    ATR:()=>10,TimeCurrent:()=>now,SameZone:()=>true,EventStillPresent:()=>true,
    ResetSetup:()=>{ctx.Stage=0;},Log:()=>{},StructureTiming:()=>'',TS:String,Price:String,
    EventAfter:(f,d,after,kind,out)=>{const closed=f===3?confirmClosed:breakClosed;
      if(closed<=after||!closed)return false;Object.assign(out,{valid:true,dir:d,closed,name:f+'|event',price:100,kind:f===3?'CHoCH':'BOS'});return true;},
    MathMax:Math.max,Issue:()=>{throw Error('Retest must be on a later bar');}};
  vm.createContext(ctx);vm.runInContext(extract('Process'),ctx);return ctx;
}
const m1=[{time:3000,open:100,high:105,low:95,close:103}],m5=[{time:2700,close:100,high:105,low:95}],tick={bid:103,ask:103.1};
for(const dir of [1,-1])test('Delayed M5 confirmation consumes fresh M1 break '+(dir>0?'BUY':'SELL'),()=>{const c=processContext(dir,3000,3060);c.Process(m1,m5,tick,false);assert.equal(c.Stage,3);assert.equal(c.BreakClosed,3060);});
test('Same-candle M5 and M1 cannot satisfy sequential confirmation',()=>{const c=processContext(1,3060,3060);c.Process(m1,m5,tick,false);assert.equal(c.Stage,2);assert.equal(c.BreakClosed,0);});
test('Historical M1 break cannot be backfilled',()=>{const c=processContext(1,2940,3000);c.Process(m1,m5,tick,false);assert.equal(c.Stage,2);assert.equal(c.BreakClosed,0);});
test('Expired setup does not use delayed confirmation',()=>{const c=processContext(1,3000,3060,6601);c.DiagnoseLate=()=>{};c.Process(m1,m5,tick,false);assert.equal(c.Stage,0);});
test('Unknown timestamps do not look like a 1970 event',()=>{const c={TimeToString:t=>new Date(t*1000).toISOString(),TIME_DATE:1,TIME_SECONDS:2};vm.createContext(c);vm.runInContext(extract('TS'),c);assert.equal(c.TS(0),'—');});
const quoteCases=[
  ['disconnected wins over session',false,true,100,1,0,'DISCONNECTED'],
  ['invalid price waits',true,false,100,99,1,'WAIT_QUOTE'],
  ['future quote exposes clock error',true,true,100,106,1,'CLOCK_ERROR'],
  ['closed session identifies old quote',true,true,100,1,0,'MARKET_CLOSED'],
  ['unknown session does not invent market closure',true,true,100,1,-1,'STALE_QUOTE'],
  ['open session with old quote stays blocked',true,true,100,1,1,'STALE_QUOTE'],
  ['fresh quote remains eligible',true,true,100,99,1,'FRESH'],
  ['age limit is inclusive',true,true,100,85,1,'FRESH']
];
for(const [name,...args] of quoteCases)test(name,()=>{const want=args.pop(),c={MaxQuoteAgeSeconds:15};vm.createContext(c);vm.runInContext(extract('QuoteHealth'),c);assert.equal(c.QuoteHealth(...args),want);});

// This catches the tick handler erasing an actionable terminal/source remedy.
for(const health of ['SOURCE_MISSING','STALE_SOURCE','DISCONNECTED','CLOCK_ERROR','LIVE'])
test('Tick gap preserves health priority '+health,()=>{
  const c={OwnObjects:true,Busy:false,LastScannedM1:3000,DataHealth:health,Primed:true,
    _Symbol:'GOLD',PERIOD_M1:1,iTime:()=>3180,Dashboard:()=>{},ArrayInitialize:()=>{}};
  vm.createContext(c);vm.runInContext(extract('OnCalculate'),c);c.OnCalculate(100,1,0,[]);
  assert.equal(c.DataHealth,health==='LIVE'?'STALE_SCAN':health);
});

function renderObjects(width,height,dpi,active=false,details=false,collapsed=false){
  const objects=new Map();
  const c={chartWidth:width,chartHeight:height,dpi,OwnObjects:true,Pfx:'TEST_',PanelWidth:340,PanelX:14,PanelY:28,
    PanelFontSize:14,PanelFont:'Leelawadee UI',PanelButtonHeight:26,PanelDetails:details,PanelCollapsed:collapsed,PanelOldRows:0,
    PanelLeft:[],PanelRight:[],PanelStyle:[],PanelTips:[],PanelBackground:1,PanelText:2,PanelMuted:3,PanelRule:4,PanelBuy:5,PanelSell:6,PanelWarning:7,
    DataHealth:'LIVE',Status:'READY',Primed:true,Active:active,ActiveDir:1,ActiveModel:'M1_ZONE_CONFIRM',Entry:4140,SL:4136,TP1:4144,TP2:4148,TP3:4152,
    ReachedTP:0,FastZones:[],NextAllowed:0,EnableM1ZoneSignals:true,LastGoodCycle:1,Latest:Array.from({length:5},()=>({valid:false,dir:1})),SignalID:'',
    FrameStatus:Array(5).fill('WAIT_SCAN'),FrameDetail:Array(5).fill(''),FrameMs:Array(5).fill(0),Stage:0,WatchHealth:'LIVE',WatchLast:'',EnableZoneTracker:true,ShowZoneTracker:true,
    LastScannedM1:3000,ShowDiagnostics:true,ZoneCheckBar:0,ZoneDetail:'',LastDecision:'No entry',LastDecisionTooltip:'',LastSourceDetail:'No change',LastSourceTooltip:'',FastStatus:'',
    _Symbol:'GOLD',TIME_MINUTES:1,TIME_SECONDS:2,TIME_DATE:4,TimeCurrent:()=>3062,TimeToString:()=> '10:06',TimeTradeServer:()=>3062,SymbolInfoTick:()=>false,
    FrameName:f=>['H4','H1','M15','M5','M1'][f],FrameAge:()=>'-',FastContext:()=> 'WITH_H1',Dir:d=>d>0?'BUY':'SELL',Price:p=>p.toFixed(2),EnumToString:String,
    ArraySize:a=>a.length,ArrayResize:(a,n)=>{a.length=n;},StringLen:s=>s.length,StringSubstr:(s,a,n)=>s.substr(a,n),IntegerToString:String,MathMin:Math.min,MathMax:Math.max,MathCeil:Math.ceil,
    Starts:(s,p)=>s.startsWith(p),StringFind:(s,p)=>s.indexOf(p),TerminalInfoInteger:()=>dpi,TextSetFont:()=>true,TextGetSize:()=>false,ChartRedraw:()=>{},
    ObjectFind:(chart,n)=>objects.has(n)?0:-1,ObjectCreate:(chart,n,type)=>{objects.set(n,{type});return true;},
    ObjectSetInteger:(chart,n,k,v)=>{objects.get(n)[k]=v;},ObjectSetString:(chart,n,k,v)=>{objects.get(n)[k]=v;},
    ObjectDelete:(chart,n)=>objects.delete(n),ObjectsDeleteAll:(chart,prefix)=>{for(const k of objects.keys())if(k.startsWith(prefix))objects.delete(k);}
  };
  for(const k of ['CHART_WIDTH_IN_PIXELS','CHART_HEIGHT_IN_PIXELS','TERMINAL_SCREEN_DPI','OBJ_LABEL','OBJ_BUTTON','OBJ_RECTANGLE_LABEL','CORNER_LEFT_UPPER','ANCHOR_RIGHT_UPPER','ANCHOR_LEFT_UPPER','BORDER_FLAT','FW_NORMAL','OBJPROP_CORNER','OBJPROP_ANCHOR','OBJPROP_XDISTANCE','OBJPROP_YDISTANCE','OBJPROP_COLOR','OBJPROP_FONTSIZE','OBJPROP_BACK','OBJPROP_SELECTABLE','OBJPROP_HIDDEN','OBJPROP_ZORDER','OBJPROP_FONT','OBJPROP_TEXT','OBJPROP_TOOLTIP','OBJPROP_XSIZE','OBJPROP_YSIZE','OBJPROP_BGCOLOR','OBJPROP_BORDER_COLOR','OBJPROP_STATE','OBJPROP_BORDER_TYPE'])c[k]=k;
  vm.createContext(c);
  for(const f of ['TS','PanelAge','PanelAdd','PanelFit','PanelLabel','PanelButton','PanelHealthText','PanelMainRows','PanelDetailRows','Dashboard']){
    let code=extract(f).replace('ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0,cw);','cw=chartWidth;').replace('ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0,ch);','ch=chartHeight;');
    vm.runInContext(code,c);
  }
  c.Dashboard();return {c,objects};
}
for(const [w,h,dpi] of [[160,260,192],[160,320,240],[320,85,192],[340,700,96],[260,400,144]])
test('Native panel rectangles remain inside viewport '+w+'x'+h+' dpi'+dpi,()=>{
  const {objects}=renderObjects(w,h,dpi);
  for(const [name,o] of objects)if(o.type==='OBJ_BUTTON'||o.type==='OBJ_RECTANGLE_LABEL'){
    assert.ok(o.OBJPROP_XDISTANCE>=0,name+' negative x');assert.ok(o.OBJPROP_YDISTANCE>=0,name+' negative y');
    assert.ok(o.OBJPROP_XDISTANCE+o.OBJPROP_XSIZE<=w,name+' exceeds chart width');
    assert.ok(o.OBJPROP_YDISTANCE+o.OBJPROP_YSIZE<=h,name+' exceeds chart height');
  }
});
test('Collapse removes old plan rows from native objects',()=>{const {c,objects}=renderObjects(340,700,96,true);c.PanelCollapsed=true;c.Dashboard();assert.equal([...objects.keys()].filter(k=>k.startsWith('TEST_ui_row_')&&k.endsWith('_left')).length,1);assert.equal(objects.has('TEST_ui_details'),false);});
console.log('RESULT '+passed+' passed, '+failures+' failed');process.exitCode=failures?1:0;
