// SMC + Pro Support Resistance MTF signals -- experimental forward-test v1.11
// Attach to M1. Keep exactly one same-symbol H4,H1,M15,M5,M1 chart open,
// each with the user's original two indicators. See README_TH.md.
// Adapter based on the user's exported objects, not reverse-engineered EX5.
// No orders, DLLs, WebRequest, or historical backfill. Closed candles only.
// Source objects can repaint. We freeze issued plans, not the source data.
#property strict
#property version "1.11"
#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots 1
#property indicator_type1 DRAW_NONE
#property indicator_label1 "MTF status placeholder"

input string InstanceTag="Main"; // Use only one instance on the M1 chart
input color SMCBullColor=C'8,153,129';
input color SMCBearColor=C'242,54,69';
input bool RequireH4Alignment=false; // H4 still supplies opposing-zone filter
input int PivotLeft=3;
input int PivotRight=3;
input int HistoryBars=300;
input int StructureHistoryBars=2000; // Separate closed-bar window for mapping SMC objects
input int ATRPeriod=14;
input double SL_ATR_Buffer=0.15;
input double SL_Spread_Multiple=2.0;
input double Retest_ATR_Tolerance=0.10;
input int SetupExpiryM5Bars=12;
input int RetestExpiryM1Bars=10;
input int CooldownM1Bars=10;
input double TP1_R=1.0;
input double TP2_R=2.0;
input double TP3_R=3.0;
input double MaxSpreadToRisk=0.20;
input double MaxEntryDeviationATR=0.50;
input bool PopupAlerts=true;
input bool PushAlerts=false;
input bool WriteAuditCSV=true;
input int PanelFontSize=10; // 7..14; Thai-capable compact panel
input int PanelWidth=340; // Pixels; automatically clamped to the chart width
input int PanelX=14;
input int PanelY=28;
input bool PanelStartCollapsed=false;
input string PanelFont="Leelawadee UI";
input bool WriteDetailedCSV=true; // Decisions and source changes; also requires WriteAuditCSV
input bool ShowDiagnostics=true; // Last WAIT_ZONE evaluation and scan progress
input bool LogZoneChecks=true; // One ZONE_CHECK per evaluated closed M5 bar
input int MaxObjectsToScan=20000; // Budget for relevant SMC/SR objects per chart

input int HTFCacheSeconds=300; // H4/H1 cache maximum age; new TF bar forces refresh
input int MaxFrameScanMs=1500; // Cooperative scan budget; cannot interrupt a blocked MT5 call
input int MaxCycleMs=8000;
input int MaxQuoteAgeSeconds=15;
input bool LogScanTiming=true;

input bool EnableZoneTracker=true; // New models OBSERVE ONLY; no alerts/orders/entry arrows
input bool ShowZoneTracker=true;
input double ZoneConfirmATR=0.05; // Frozen confirmation buffer, at least two ticks
input double ZoneRetestATR=0.10; // Frozen zone-edge retest tolerance
input int ZoneReactionBars=6; // Closed M5 bars after touch, including touch bar
input int ZoneRetestBars=6; // Subsequent closed M5 bars after breakout
input int ZoneObserveBars=12; // Total observation lifetime, closed M5 time
input int MaxTrackedZones=64;

input bool EnableM1ZoneSignals=true; // Touch zone -> closed M1 micro-break -> Entry/SL/TP
input bool FastUseM5Zones=true;
input bool FastUseM1Swings=true; // Last two confirmed 2L/2R pivots per side; source labelled M1_SWING
input bool FastAllowCounterH1=true; // H1 is labelled context; false requires alignment
input bool FastTouchAlerts=false; // Yellow touch dots are always preliminary; optional popup
input int FastSetupM1Bars=10;
input int FastCooldownM1Bars=2;
input int FastPlanM1Bars=30; // Retire the displayed fast plan after this time; no trade is closed
input double FastSwingWidthATR=0.15;
input double FastBreakATR=0.05;
input double FastMinBodyFraction=0.35;

bool PanelCollapsed=false,PanelDetails=false;
int PanelOldRows=0,PanelButtonHeight=26;
string PanelLeft[],PanelRight[],PanelTips[];
int PanelStyle[];
color PanelBackground=C'24,35,45',PanelText=C'237,242,246',PanelMuted=C'186,200,212';
color PanelRule=C'59,73,87',PanelBuy=C'125,213,179',PanelSell=C'245,155,166',PanelWarning=C'255,204,121';

bool FrameCached[5];
datetime CachedBar[5];
ulong CachedAt[5],FrameMs[5],ScanStarted=0,LastChartsCheck=0,LastGoodCycle=0;
long CachedChart[5];
string DataHealth="STARTING";
string SnapshotIssue="";
bool ChartSetReady=false;

double HiddenBuffer[];
ENUM_TIMEFRAMES Frames[5]={PERIOD_H4,PERIOD_H1,PERIOD_M15,PERIOD_M5,PERIOD_M1};
long Charts[5];
string FrameStatus[5],FrameDetail[5],LastFrameCode[5];
ulong RetryAfter=0;
string Pfx,Status="Starting",AuditFile,LastPlan="No signal issued";
int Audit=INVALID_HANDLE;
bool Primed=false,Busy=false,OwnObjects=false;
datetime LastM1=0,LastM5=0,NextAllowed=0;
double TickSize=0;
ulong TimerPulses=0;
datetime LastScannedM1=0;
string M1Clock="STARTING";
datetime ZoneCheckBar=0;
int ZoneCheckBias=0,ZoneTotal=0,ZoneEligible=0,ZoneTouched=0,ZoneQualified=0;
bool ZonePivotFound=false,ZoneBreach=false,ZoneReclaim=false;
double ZonePivot=0;
string ZoneReason="NOT_CHECKED",ZoneRange="--",ZoneDetail="";

struct StructureEvent
{
   bool valid;
   int dir;
   string kind,name;
   double price;
   datetime candle,closed;
};
struct Zone
{
   int side,frame; // +1 support; -1 resistance
   string name;
   double low,high;
   datetime start;
};
struct FastZone
{
   Zone zone; string id;
   datetime since,armed,touched;
   double trigger,extreme,stop;
   bool present,detached,swing,previewed,terminal;
};
FastZone FastZones[];
long FastSerial=0;
bool FastCapacity=false;
datetime LastFastClosed=0,ActiveSince=0;
string FastStatus="WAIT_SYNC",ActiveModel="STRICT_SWEEP";
string OwnerKey=""; double OwnerToken=0;

StructureEvent Latest[5],Events[];
Zone Zones[];
struct RawZone { Zone zone; bool eligible,read_ok; string exclusion; };
struct EventSeen { StructureEvent event; datetime seen; };
struct ObstacleInfo
{
   bool found,inside; int frame;
   double room,edge,pad,low,high; string name,key,ties;
};
struct EntryDecision
{
   int code; string reason,gates;
   double entry,stop,risk,spread,trigger,atr,deviation,allowed,required,t1,t2,t3;
   ObstacleInfo obstacle;
};
RawZone RawZones[];
EventSeen SeenEvents[];
bool RawZoneReadOK=true;
long SnapshotSerial=0,DiagnosticSeq=0;
int DecisionsCSV=INVALID_HANDLE,SourcesCSV=INVALID_HANDLE;
string DecisionsFile="",SourcesFile="",StrictSetupID="--";
string LastDecision="No entry check yet",LastDecisionRoom="",LastDecisionSource="",LastDecisionTooltip="";
string LastSourceDetail="No source change",LastSourceTooltip="",WatchSelected="",WatchLastTerminal="No terminal setup yet";

enum Phase { WAIT_ZONE=0, WAIT_M5_CHOCH=1, WAIT_M1_BREAK=2, WAIT_M1_RETEST=3 };
Phase Stage=WAIT_ZONE;
Zone SetupZone;
int SetupDir=0;
datetime SweepClosed=0,ConfirmClosed=0,BreakClosed=0,Expiry=0;
double Stop=0,BreakPrice=0,ConfirmPrice=0;
string ConfirmName="",BreakName="";
bool Active=false;
int ActiveDir=0,ReachedTP=0;
double Entry=0,SL=0,TP1=0,TP2=0,TP3=0;
string SignalID="";

// Zone observers never change the strict entry engine or issue live signals.
struct ZoneWatch
{
   Zone zone;
   string id,setup,state,model,gate,confirm_name,break_name;
   string metadata_name,last_event; datetime last_event_closed,last_event_seen;
   datetime seen,armed,started,reaction,breakout,retest,confirmed,broken,last_m5,last_m1;
   double buffer,tolerance,pad,extreme,stop,confirm_price,break_price;
   int direction;
   bool terminal;
};
ZoneWatch Watches[];
long WatchSerial=0,WatchSetupSerial=0;
string WatchSession="",WatchLast="No zone event yet",WatchHealth="STARTING";
string SyncReason="INITIAL_START";
datetime WatchM5=0;

string Dir(int d) { return d>0 ? "BUY" : (d<0 ? "SELL" : "UNKNOWN"); }
string Price(double p) { return DoubleToString(p,_Digits); }
string Exact(double p) { return DoubleToString(p,16); }
string TS(datetime t) { return t<=0 ? "—" : TimeToString(t,TIME_DATE|TIME_SECONDS); }
bool Starts(string s,string prefix) { return StringFind(s,prefix)==0; }
double Up(double p) { return NormalizeDouble(MathCeil(p/TickSize-1e-8)*TickSize,_Digits); }
double Down(double p) { return NormalizeDouble(MathFloor(p/TickSize+1e-8)*TickSize,_Digits); }

string CSV(string s)
{
   StringReplace(s,"\"","\"\"");
   return "\""+s+"\"";
}

void Log(string event,string detail)
{
   Print("SMC MTF | ",event," | ",detail);
   if(Audit!=INVALID_HANDLE)
   {
      if(FileWriteString(Audit,CSV(TS(TimeCurrent()))+","+CSV(_Symbol)+","+
                         CSV(event)+","+CSV(detail)+"\r\n")==0)
         Print("SMC MTF: audit write failed, error=",GetLastError());
      FileFlush(Audit);
   }
}

void ResetSetup(string why)
{
   if(Stage!=WAIT_ZONE) Log("RESET",why);
   StrictSetupID="--";
   Stage=WAIT_ZONE; SetupDir=0; SweepClosed=0; ConfirmClosed=0;
   BreakClosed=0; Expiry=0; Stop=0; BreakPrice=0; ConfirmPrice=0;
   ConfirmName=""; BreakName=""; Status=why;
}

bool Rates(ENUM_TIMEFRAMES tf,MqlRates &r[])
{
   ArraySetAsSeries(r,true);
   return CopyRates(_Symbol,tf,1,HistoryBars,r)==HistoryBars;
}

// Exact timestamp only; r[] must run newest to oldest and contain closed bars.
int ClosedBarIndex(MqlRates &r[],datetime stamp)
{
   int lo=0,hi=ArraySize(r)-1;
   while(lo<=hi)
   {
      int mid=lo+(hi-lo)/2;
      if(r[mid].time==stamp) return mid;
      if(r[mid].time>stamp) lo=mid+1;
      else hi=mid-1;
   }
   return -1;
}

bool FrameResult(int f,string code,string detail,bool ok)
{
   FrameStatus[f]=code; FrameDetail[f]=detail;
   if(LastFrameCode[f]!=code)
   {
      Log("MAP_STATUS",EnumToString(Frames[f])+" "+code+" | "+detail);
      LastFrameCode[f]=code;
   }
   if(!ok) Latest[f].valid=false;
   return ok;
}
double ATR(MqlRates &r[])
{
   if(ArraySize(r)<ATRPeriod+1) return 0;
   double sum=0;
   for(int k=0;k<ATRPeriod;k++)
      sum+=MathMax(r[k].high-r[k].low,
             MathMax(MathAbs(r[k].high-r[k+1].close),MathAbs(r[k].low-r[k+1].close)));
   return sum/ATRPeriod; // SMA of true range, deliberately not Wilder smoothing
}

// Most recent strict pivot confirmed BEFORE r[0] (the prospective sweep).
bool Pivot(MqlRates &r[],int side,double &price)
{
   for(int i=PivotRight+1;i<ArraySize(r)-PivotLeft;i++)
   {
      double p=side>0 ? r[i].low : r[i].high;
      bool ok=true;
      for(int j=1;j<=PivotLeft && ok;j++)
         if(side>0 ? r[i+j].low<=p : r[i+j].high>=p) ok=false;
      for(int j=1;j<=PivotRight && ok;j++)
         if(side>0 ? r[i-j].low<=p : r[i-j].high>=p) ok=false;
      if(ok) { price=p; return true; }
   }
   return false;
}

string Pass(bool value) { return value ? "PASS" : "FAIL"; }

// Same entry rules as v1.01. Evaluate all parts for diagnostics even when
// one part fails. Only called for a new closed M5 bar while in WAIT_ZONE.
bool EvaluateZone(MqlRates &m5[],int bias,int &selected,double &pivot)
{
   ZoneCheckBar=m5[0].time; ZoneCheckBias=bias;
   ZoneTotal=0; ZoneEligible=0; ZoneTouched=0; ZoneQualified=0;
   selected=-1; pivot=0;
   ZonePivotFound=Pivot(m5,bias,pivot); ZonePivot=pivot;
   ZoneBreach=ZonePivotFound && (bias>0 ? m5[0].low<pivot : m5[0].high>pivot);
   ZoneReclaim=ZonePivotFound && (bias>0 ? m5[0].close>pivot : m5[0].close<pivot);
   int nearest=-1;
   double nearest_distance=1e30,best=1e30;
   for(int i=0;i<ArraySize(Zones);i++)
   {
      Zone z=Zones[i];
      if(z.frame!=2) continue;
      ZoneTotal++;
      if(z.side!=bias || z.start>m5[0].time) continue;
      ZoneEligible++;
      double distance=MathAbs(m5[0].close-(z.low+z.high)/2);
      if(distance<nearest_distance) { nearest_distance=distance; nearest=i; }
      if(m5[0].high<z.low || m5[0].low>z.high) continue;
      ZoneTouched++;
      if(bias>0 ? m5[0].close<z.low : m5[0].close>z.high) continue;
      ZoneQualified++;
      if(distance<best) { selected=i; best=distance; }
   }
   bool ok=ZonePivotFound && ZoneBreach && ZoneReclaim && selected>=0;
   if(ok) ZoneReason="PASS";
   else if(ZoneTotal==0) ZoneReason="NO_M15_ZONES";
   else if(ZoneEligible==0) ZoneReason="NO_ELIGIBLE_ZONE";
   else if(!ZonePivotFound) ZoneReason="NO_CONFIRMED_PIVOT";
   else if(ZoneTouched==0) ZoneReason="NO_ZONE_TOUCH";
   else if(!ZoneBreach) ZoneReason="NO_PIVOT_SWEEP";
   else if(!ZoneReclaim) ZoneReason="NO_CLOSE_BACK";
   else ZoneReason="ZONE_CLOSE_FAILED";
   int shown=selected>=0 ? selected : nearest;
   ZoneRange=shown>=0 ? Price(Zones[shown].low)+".."+Price(Zones[shown].high) : "--";
   ZoneDetail="M5_open="+TS(m5[0].time)+" M5_closed="+TS(m5[0].time+300)+
      " bias="+Dir(bias)+" O="+Price(m5[0].open)+" H="+Price(m5[0].high)+
      " L="+Price(m5[0].low)+" C="+Price(m5[0].close)+
      " zones_total="+IntegerToString(ZoneTotal)+" eligible="+IntegerToString(ZoneEligible)+
      " touched="+IntegerToString(ZoneTouched)+" close_ok="+IntegerToString(ZoneQualified)+
      " pivot="+(ZonePivotFound ? Price(pivot) : "NONE")+
      " breach="+(ZonePivotFound ? Pass(ZoneBreach) : "N/A")+
      " close_back="+(ZonePivotFound ? Pass(ZoneReclaim) : "N/A")+
      " result="+ZoneReason+" shown_zone="+(shown>=0 ? Zones[shown].name : "NONE")+
      " range="+ZoneRange+" zone_role="+(selected>=0 ? "QUALIFIED" : "NEAREST_BY_MIDPOINT");
   if(LogZoneChecks) Log("ZONE_CHECK",ZoneDetail);
   return ok;
}

bool HasOriginals(long chart)
{
   bool smc=false,sr=false;
   int n=ChartIndicatorsTotal(chart,0);
   for(int i=0;i<n;i++)
   {
      string name=ChartIndicatorName(chart,0,i);
      if(StringFind(name,"Smart Money Concepts")>=0) smc=true;
      if(StringFind(name,"Pro Support Resistance")>=0) sr=true;
   }
   return smc && sr;
}

bool FindCharts()
{
   for(int f=0;f<5;f++) Charts[f]=-1;
   long c=ChartFirst();
   while(c>=0)
   {
      if(ChartSymbol(c)==_Symbol)
         for(int f=0;f<5;f++)
            if(ChartPeriod(c)==Frames[f])
            {
               if(Charts[f]>=0)
               { Status="Duplicate charts: "+EnumToString(Frames[f])+" (keep one)"; return false; }
               Charts[f]=c;
            }
      c=ChartNext(c);
   }
   for(int f=0;f<5;f++)
   {
      if(Charts[f]<0) { Status="Open "+_Symbol+" "+EnumToString(Frames[f]); return false; }
      if(!HasOriginals(Charts[f]))
      { Status="Attach both originals: "+EnumToString(Frames[f]); return false; }
   }
   return true;
}

// Match a canonical structure line to a canonical BOS/CHoCH text label.
// A label's centre time is NOT the event time. Use the line's endpoint,
// then require the corresponding candle to be closed and beyond the line.
bool ReadFrame(int f)
{
   Latest[f].valid=false; Latest[f].dir=0;
   long c=Charts[f];
   string relevant[];
   int count=0;
   ENUM_OBJECT types[3]={OBJ_TREND,OBJ_TEXT,OBJ_RECTANGLE};
   for(int t=0;t<3;t++)
   {
      if(!ScanBudget(f)) return false;
      int total=ObjectsTotal(c,0,types[t]);
      if(total<0) return FrameResult(f,"OBJECT_READ_FAILED","Cannot enumerate objects",false);
      for(int i=0;i<total;i++)
      {
         if(!ScanBudget(f)) return false;
         string n=ObjectName(c,i,0,types[t]);
         if(f==2 && n=="") RawZoneReadOK=false;
         if(!Starts(n,"iSMC_str_lbl_") && !Starts(n,"iSMC_str_line_") && !Starts(n,"SSSR#")) continue;
         count++;
         if(count>MaxObjectsToScan)
            return FrameResult(f,"OBJECT_LIMIT","Relevant objects exceed limit",false);
         ArrayResize(relevant,count,256); relevant[count-1]=n;
      }
   }
   MqlRates rr[];
   ArraySetAsSeries(rr,true);
   int copied=CopyRates(_Symbol,Frames[f],1,StructureHistoryBars,rr);
   if(copied!=StructureHistoryBars)
      return FrameResult(f,"LOADING_HISTORY","Closed bars="+IntegerToString(copied)+
                         "/"+IntegerToString(StructureHistoryBars),false);
   string names[],texts[];
   double prices[];
   long colors[];
   datetime times[];
   int labels=0;
   for(int i=0;i<count;i++)
   {
      if(!ScanBudget(f)) return false;
      string n=relevant[i];
      if(Starts(n,"iSMC_str_lbl_"))
      {
         string txt=ObjectGetString(c,n,OBJPROP_TEXT);
         StringTrimLeft(txt); StringTrimRight(txt);
         if(txt!="BOS" && txt!="CHoCH") continue;
         ArrayResize(names,labels+1); ArrayResize(texts,labels+1);
         ArrayResize(prices,labels+1); ArrayResize(colors,labels+1); ArrayResize(times,labels+1);
         names[labels]=n; texts[labels]=txt;
         prices[labels]=ObjectGetDouble(c,n,OBJPROP_PRICE,0);
         colors[labels]=ObjectGetInteger(c,n,OBJPROP_COLOR);
         times[labels]=(datetime)ObjectGetInteger(c,n,OBJPROP_TIME,0);
         labels++;
      }
   }
   int canonical_lines=0;
   int bad_shape=0,bad_color=0,bad_time=0,old_bar=0,missing_bar=0;
   int close_fail=0,label_fail=0,accepted=0;
   bool latest_ambiguous=false;
   for(int i=0;i<count;i++)
   {
      if(!ScanBudget(f)) return false;
      string n=relevant[i];
      if(Starts(n,"iSMC_str_lbl_")) continue;
      ResetLastError();
      long typ=ObjectGetInteger(c,n,OBJPROP_TYPE);
      if(f==2 && GetLastError()!=0) RawZoneReadOK=false;
      if(Starts(n,"SSSR#") && typ==OBJ_RECTANGLE)
      {
         bool support=Starts(n,"SSSR#S"), resistance=Starts(n,"SSSR#R");
         if(!support && !resistance) continue;
         bool strength=StringFind(n,"Strength=Verified")>=0 || StringFind(n,"Strength=Un-Mitigated")>=0;
         ResetLastError();
         double a=ObjectGetDouble(c,n,OBJPROP_PRICE,0),b=ObjectGetDouble(c,n,OBJPROP_PRICE,1);
         Zone z; z.side=support ? 1 : -1; z.frame=f; z.name=n;
         z.low=MathMin(a,b); z.high=MathMax(a,b);
         z.start=(datetime)ObjectGetInteger(c,n,OBJPROP_TIME,0);
         bool read_ok=GetLastError()==0;
         bool shape=a>0 && b>0 && MathAbs(a-b)>=TickSize;
         bool stamp=z.start>0 && z.start<=rr[0].time;
         string exclusion=!read_ok ? "READ_ERROR" : (!strength ? "STRENGTH_FILTER" :
                          (!shape ? "INVALID_BOUNDS" : (!stamp ? "INVALID_START" : "NONE")));
         CaptureRawZone(z,strength && shape && stamp,exclusion,read_ok);
         if(!strength || !shape || !stamp) continue;
         int size=ArraySize(Zones); ArrayResize(Zones,size+1); Zones[size]=z;
      }
      if(!Starts(n,"iSMC_str_line_") || typ!=OBJ_TREND) continue;
      canonical_lines++;
      double p=ObjectGetDouble(c,n,OBJPROP_PRICE,0);
      double p2=ObjectGetDouble(c,n,OBJPROP_PRICE,1);
      if(p<=0 || MathAbs(p-p2)>TickSize) { bad_shape++; continue; }
      long col=ObjectGetInteger(c,n,OBJPROP_COLOR);
      int d=col==(long)SMCBullColor ? 1 : (col==(long)SMCBearColor ? -1 : 0);
      if(d==0) { bad_color++; continue; }
      datetime a=(datetime)ObjectGetInteger(c,n,OBJPROP_TIME,0);
      datetime b=(datetime)ObjectGetInteger(c,n,OBJPROP_TIME,1);
      if(a<=0 || b<a) { bad_time++; continue; }
      int k=ClosedBarIndex(rr,b);
      if(k<0)
      {
         if(b<rr[ArraySize(rr)-1].time) old_bar++;
         else missing_bar++; // Includes forming bars and non-exact timestamps
         continue;
      }
      if(d>0 ? rr[k].close<=p : rr[k].close>=p) { close_fail++; continue; }
      int label=-1; double best=1e30;
      bool ambiguous=false;
      for(int j=0;j<labels;j++)
      {
         if((j%64)==0 && !ScanBudget(f)) return false;
         if(colors[j]!=col || MathAbs(prices[j]-p)>TickSize || times[j]<a || times[j]>b) continue;
         double distance=MathAbs((double)times[j]-((double)a+(double)b)/2.0);
         if(distance<best) { best=distance; label=j; ambiguous=false; }
         else if(distance==best && label>=0 && texts[j]!=texts[label]) ambiguous=true;
      }
      if(label<0 || ambiguous) { label_fail++; continue; }
      accepted++;
      StructureEvent e; e.valid=true; e.dir=d; e.name=n; e.kind=texts[label];
      e.price=p; e.candle=b; e.closed=b+PeriodSeconds(Frames[f]);
      if(!Latest[f].valid || e.closed>Latest[f].closed)
      { Latest[f]=e; latest_ambiguous=false; }
      else if(e.closed==Latest[f].closed && e.dir!=Latest[f].dir) latest_ambiguous=true;
      if(f==3 || f==4)
      {
         // Prefix TF to keep event lookup distinct without modifying source objects.
         e.name=IntegerToString(f)+"|"+e.name;
         int size=ArraySize(Events); ArrayResize(Events,size+1); Events[size]=e;
      }
   }
   string detail="lines="+IntegerToString(canonical_lines)+" labels="+IntegerToString(labels)+
      " accepted="+IntegerToString(accepted)+" old="+IntegerToString(old_bar)+
      " no_closed_bar="+IntegerToString(missing_bar)+" color="+IntegerToString(bad_color)+
      " close="+IntegerToString(close_fail)+" label="+IntegerToString(label_fail)+
      " shape="+IntegerToString(bad_shape)+" time="+IntegerToString(bad_time)+
      " range="+TS(rr[ArraySize(rr)-1].time)+".."+TS(rr[0].time);
   if(latest_ambiguous) return FrameResult(f,"CONFLICTING_STRUCTURE",detail,false);
   if(!Latest[f].valid)
   {
      string code="NO_CONFIRMED_STRUCTURE";
      if(canonical_lines==0) code="NO_SMC_LINES";
      else if(labels==0) code="NO_BOS_CHOCH_LABELS";
      else if(label_fail>0) code="LABEL_MATCH_FAILED";
      else if(close_fail>0) code="CLOSE_NOT_CONFIRMED";
      else if(missing_bar>0) code="NO_EXACT_CLOSED_BAR";
      else if(old_bar>0) code="OUTSIDE_HISTORY";
      else if(bad_color>0) code="COLOR_NOT_MAPPED";
      else if(bad_time>0) code="INVALID_LINE_TIME";
      else if(bad_shape>0) code="INVALID_LINE_PRICE";
      return FrameResult(f,code,detail,false);
   }
   detail+=" latest="+Dir(Latest[f].dir)+" "+Latest[f].kind+" endpoint="+TS(Latest[f].candle);
   return FrameResult(f,"OK",detail,true);
}

int FrameTTL(int f)
{
   if(f<=1) return HTFCacheSeconds;
   if(f==2) return 60;
   if(f==3) return 30;
   return 0;
}

bool CacheUsable(int f,datetime bar,ulong now)
{
   // Reserve a full bounded cycle: other frames can take time to read.
   // A cache valid here must not expire before the final freshness gate.
   ulong ttl=(ulong)FrameTTL(f)*1000;
   ulong reserve=(ulong)MaxCycleMs;
   return FrameCached[f] && Latest[f].valid && CachedChart[f]==Charts[f] &&
          bar>0 && CachedBar[f]==bar && now>=CachedAt[f] && ttl>reserve &&
          now-CachedAt[f]<ttl-reserve;
}

void DropFrame(int f)
{
   if(f==2) { ArrayResize(RawZones,0); RawZoneReadOK=true; }
   int n=0;
   for(int i=0;i<ArraySize(Zones);i++)
      if(Zones[i].frame!=f) { Zones[n]=Zones[i]; n++; }
   ArrayResize(Zones,n);
   n=0;
   for(int i=0;i<ArraySize(Events);i++)
      if(!Starts(Events[i].name,IntegerToString(f)+"|")) { Events[n]=Events[i]; n++; }
   ArrayResize(Events,n);
}

bool SnapshotFresh()
{
   SnapshotIssue="";
   for(int f=0;f<5;f++)
   {
      if(!FrameCached[f] || !Latest[f].valid || CachedChart[f]!=Charts[f] ||
         CachedBar[f]<=0 || CachedBar[f]!=iTime(_Symbol,Frames[f],0))
      { SnapshotIssue=EnumToString(Frames[f])+" CACHE_INVALID_OR_BAR_CHANGED"; return false; }
      int max_age=(f==4 ? MaxCycleMs : FrameTTL(f)*1000);
      ulong now=GetTickCount64();
      if(now<CachedAt[f] || now-CachedAt[f]>(ulong)max_age)
      {
         SnapshotIssue=EnumToString(Frames[f])+" CACHE_EXPIRED age_ms="+
                       IntegerToString((long)(now-CachedAt[f]))+" limit_ms="+IntegerToString(max_age);
         return false;
      }
   }
   return true;
}

bool Snapshot()
{
   ulong cycle=GetTickCount64();
   for(int f=0;f<5;f++)
   {
      datetime bar=iTime(_Symbol,Frames[f],0);
      if(CacheUsable(f,bar,GetTickCount64())) continue;
      FrameCached[f]=false; DropFrame(f);
      DataHealth="SCANNING "+EnumToString(Frames[f]);
      Dashboard();
      if(LogScanTiming) Log("SCAN_BEGIN",EnumToString(Frames[f]));
      ScanStarted=GetTickCount64();
      bool ok=ReadFrame(f);
      FrameMs[f]=GetTickCount64()-ScanStarted;
      if(FrameMs[f]>(ulong)MaxFrameScanMs)
         ok=FrameResult(f,"SCAN_TIMEOUT","ms="+IntegerToString((long)FrameMs[f]),false);
      if(bar<=0 || bar!=iTime(_Symbol,Frames[f],0))
         ok=FrameResult(f,"BAR_CHANGED","TF changed while scanning",false);
      if(LogScanTiming) Log("SCAN_END",EnumToString(Frames[f])+" ms="+
                           IntegerToString((long)FrameMs[f])+" "+FrameStatus[f]);
      if(!ok)
      { DropFrame(f); Status="WAIT: "+EnumToString(Frames[f])+" "+FrameStatus[f]; return false; }
      FrameCached[f]=true; CachedBar[f]=bar; CachedChart[f]=Charts[f]; CachedAt[f]=ScanStarted;
      if(GetTickCount64()-cycle>(ulong)MaxCycleMs)
      { Status="WAIT: cycle exceeded time budget"; return false; }
   }
   return true;
}

bool ScanBudget(int f)
{
   if(GetTickCount64()-ScanStarted<=(ulong)MaxFrameScanMs) return true;
   FrameResult(f,"SCAN_TIMEOUT","Scan budget reached; partial data discarded",false);
   return false;
}

bool SameZone(Zone &z)
{
   for(int i=0;i<ArraySize(Zones);i++)
      if(Zones[i].frame==z.frame && Zones[i].start==z.start && Zones[i].side==z.side &&
         MathAbs(Zones[i].low-z.low)<=TickSize && MathAbs(Zones[i].high-z.high)<=TickSize) return true;
   return false;
}

bool EventAfter(int frame,int direction,datetime after,string kind,StructureEvent &out)
{
   out.valid=false;
   for(int i=0;i<ArraySize(Events);i++)
   {
      if(!Starts(Events[i].name,IntegerToString(frame)+"|") || Events[i].dir!=direction ||
         Events[i].closed<=after || (kind!="" && Events[i].kind!=kind)) continue;
      if(!out.valid || Events[i].closed>out.closed) out=Events[i];
   }
   return out.valid;
}

bool EventStillPresent(string name,datetime closed,double price,int dir)
{
   if(name=="") return true;
   for(int i=0;i<ArraySize(Events);i++)
      if(Events[i].name==name && Events[i].closed==closed && Events[i].dir==dir &&
         MathAbs(Events[i].price-price)<=TickSize) return true;
   return false;
}

// Compact native MT5 panel. Presentation never advances an entry engine.
string QuoteHealth(bool connected,bool valid,datetime now,datetime quoted,int session)
{
   if(!connected) return "DISCONNECTED";
   if(!valid || quoted<=0) return "WAIT_QUOTE";
   if(quoted>now+5) return "CLOCK_ERROR";
   if(now-quoted>MaxQuoteAgeSeconds)
      return session==0 ? "MARKET_CLOSED" : "STALE_QUOTE";
   return "FRESH";
}

// Quote sessions, not inferred weekend hours. Unknown schedules stay unknown.
int QuoteSessionState(datetime now)
{
   if(now<=0 || !SymbolIsSynchronized(_Symbol)) return -1;
   MqlDateTime tm; if(!TimeToStruct(now,tm)) return -1;
   int seconds=tm.hour*3600+tm.min*60+tm.sec;
   int previous=(tm.day_of_week+6)%7;
   bool known=false;
   for(int day=0;day<7;day++)
      for(uint index=0;index<32;index++)
      {
         datetime from=0,to=0;
         if(!SymbolInfoSessionQuote(_Symbol,(ENUM_DAY_OF_WEEK)day,index,from,to)) break;
         known=true;
         long start=(long)from%86400,finish=(long)to;
         // The API can encode midnight as 0 or as 86400.
         if(finish>86400) finish%=86400;
         if(start==finish) { if(day==tm.day_of_week) return 1; continue; }
         if(finish>start)
         { if(day==tm.day_of_week && seconds>=start && seconds<finish) return 1; }
         else if((day==tm.day_of_week && seconds>=start) || (day==previous && seconds<finish)) return 1;
      }
   return known ? 0 : -1;
}

string PanelAge(long seconds)
{
   if(seconds<0) return "—";
   if(seconds<60) return IntegerToString(seconds)+" วินาที";
   if(seconds<3600) return IntegerToString(seconds/60)+" นาที";
   if(seconds<86400) return IntegerToString(seconds/3600)+" ชม. "+IntegerToString((seconds%3600)/60)+" นาที";
   return IntegerToString(seconds/86400)+" วัน "+IntegerToString((seconds%86400)/3600)+" ชม.";
}

void PanelAdd(string left,string right="",int style=0,string tooltip="")
{
   int n=ArraySize(PanelLeft); ArrayResize(PanelLeft,n+1); ArrayResize(PanelRight,n+1);
   ArrayResize(PanelStyle,n+1); ArrayResize(PanelTips,n+1);
   PanelLeft[n]=left; PanelRight[n]=right; PanelStyle[n]=style;
   PanelTips[n]=tooltip=="" ? left+(right!="" ? ": "+right : "") : tooltip;
}

string PanelFit(string text,int width,int font)
{
   uint w=0,h=0;
   if(width<=0) return "";
   TextSetFont(PanelFont,-10*font,FW_NORMAL);
   if(!TextGetSize(text,w,h)) return StringSubstr(text,0,MathMax(1,width/(font+1)));
   if((int)w<=width) return text;
   int lo=0,hi=StringLen(text);
   while(lo<hi)
   {
      int mid=(lo+hi+1)/2;
      if(!TextGetSize(StringSubstr(text,0,mid)+"…",w,h)) break;
      if((int)w<=width) lo=mid; else hi=mid-1;
   }
   return StringSubstr(text,0,lo)+"…";
}

void PanelLabel(string id,int x,int y,string text,color ink,int font,int width,bool right=false,string tooltip="")
{
   string name=Pfx+"ui_"+id;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,right ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_COLOR,ink); ObjectSetInteger(0,name,OBJPROP_FONTSIZE,font);
   ObjectSetInteger(0,name,OBJPROP_BACK,false); ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true); ObjectSetInteger(0,name,OBJPROP_ZORDER,2);
   ObjectSetString(0,name,OBJPROP_FONT,PanelFont);
   ObjectSetString(0,name,OBJPROP_TEXT,PanelFit(text,width,font));
   ObjectSetString(0,name,OBJPROP_TOOLTIP,tooltip=="" ? text : tooltip);
}

void PanelButton(string id,int x,int y,int width,string caption,bool pressed=false)
{
   string name=Pfx+"ui_"+id;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,width); ObjectSetInteger(0,name,OBJPROP_YSIZE,PanelButtonHeight);
   ObjectSetInteger(0,name,OBJPROP_COLOR,PanelText); ObjectSetInteger(0,name,OBJPROP_BGCOLOR,PanelRule);
   ObjectSetInteger(0,name,OBJPROP_BORDER_COLOR,PanelRule); ObjectSetInteger(0,name,OBJPROP_FONTSIZE,PanelFontSize);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,10); ObjectSetInteger(0,name,OBJPROP_STATE,pressed);
   ObjectSetString(0,name,OBJPROP_FONT,PanelFont); ObjectSetString(0,name,OBJPROP_TEXT,caption);
}

string PanelHealthText()
{
   if(DataHealth=="LIVE" && Primed) return "● ข้อมูลพร้อม";
   if(DataHealth=="DISCONNECTED") return "● ไม่ได้เชื่อมต่อ";
   if(DataHealth=="MARKET_CLOSED") return "● นอกช่วงรับราคา";
   if(DataHealth=="STALE_QUOTE" || DataHealth=="WAIT_QUOTE") return "● ราคายังไม่พร้อม";
   if(DataHealth=="CLOCK_ERROR") return "● เวลา quote ผิดปกติ";
   if(Starts(DataHealth,"SCANNING")) return "● กำลังอ่านต้นทาง";
   if(DataHealth=="SOURCE_MISSING" || DataHealth=="STALE_SOURCE") return "● ต้นทางไม่พร้อม";
   if(DataHealth=="STARTING") return "● กำลังเริ่มต้น";
   return "● รอตรวจข้อมูล";
}

void PanelMainRows()
{
   bool live=DataHealth=="LIVE" && Primed;
   int pending=-1,armed=0;
   for(int i=0;i<ArraySize(FastZones);i++)
   {
      if(FastZones[i].terminal) continue;
      if(FastZones[i].armed>0) armed++;
      if(pending<0 && FastZones[i].touched>0) pending=i;
   }
   string title="กำลังเตรียมข้อมูล",hint="รอตรวจราคาสดและกราฟต้นทาง";
   if(!live)
   {
      if(DataHealth=="DISCONNECTED") { title="ยังไม่เชื่อมต่อ"; hint="ตรวจการเชื่อมต่อ MT5 ด้านล่างขวา"; }
      else if(DataHealth=="MARKET_CLOSED") { title="นอกช่วงรับราคา"; hint="ตามตารางโบรกเกอร์ · รอ quote ใหม่"; }
      else if(DataHealth=="STALE_QUOTE" || DataHealth=="WAIT_QUOTE") { title="รอราคาล่าสุด"; hint="ตรวจการเชื่อมต่อและช่วงรับราคา"; }
      else if(DataHealth=="CLOCK_ERROR") { title="ตรวจเวลาเครื่อง"; hint="เวลา quote อยู่ข้างหน้าเวลา server"; }
      else if(DataHealth=="SOURCE_MISSING")
      {
         title="ตรวจกราฟต้นทาง"; hint="เปิด H4 H1 M15 M5 M1 ให้ครบ";
         for(int f=0;f<5;f++)
            if(StringFind(Status,EnumToString(Frames[f]))>=0)
            {
               if(Starts(Status,"Open ")) { title="เปิดกราฟ "+_Symbol+" "+FrameName(f); hint="ใส่ Indicator ต้นทางทั้งสองบนกราฟนี้"; }
               else if(Starts(Status,"Attach both")) { title="ใส่ Indicator บน "+FrameName(f); hint="ต้องมี SMC และ Pro Support Resistance"; }
               else if(Starts(Status,"Duplicate")) { title="กราฟ "+FrameName(f)+" ซ้ำ"; hint="เหลือหนึ่งกราฟต่อ Symbol / Timeframe"; }
               break;
            }
      }
      else if(DataHealth=="STALE_HISTORY") { title="รอประวัติแท่งราคา"; hint="เปิดกราฟต้นทางและรอโหลดข้อมูล"; }
      else if(DataHealth=="STALE_SOURCE") { title="อ่านต้นทางยังไม่ครบ"; hint="ดู Timeframe และเหตุผลในรายละเอียด"; }
      else if(Starts(DataHealth,"SCANNING")) { title="กำลังอ่านต้นทาง"; hint="รอให้ตรวจข้อมูลครบก่อนออกสัญญาณ"; }
      else if(DataHealth=="STALE_SCAN" || DataHealth=="STALE") { title="รอสแกนข้อมูลใหม่"; hint="การประเมินครั้งก่อนยังใช้เข้าไม่ได้"; }
      PanelAdd(title,"",1); PanelAdd(hint,"",2,"DataHealth="+DataHealth+" | "+Status);
   }
   if(Active)
   {
      PanelAdd(Dir(ActiveDir)+(live ? " · มีแผนติดตาม" : " · แผนเดิม"),"",ActiveDir>0 ? 3 : 4);
      PanelAdd(ActiveModel=="M1_ZONE_CONFIRM" ? "M1 Zone Confirm" : "Strict Sweep","",2);
      PanelAdd("Entry",Price(Entry),5); PanelAdd("SL",Price(SL));
      PanelAdd("TP1",Price(TP1)); PanelAdd("TP2",Price(TP2)); PanelAdd("TP3",Price(TP3));
      PanelAdd("แตะเป้าหมายแล้ว",ReachedTP>0 ? "TP"+IntegerToString(ReachedTP) : "—");
      if(live) PanelAdd("บริบท H1",FastContext(ActiveDir));
      return;
   }
   if(!live)
   {
      MqlTick q;
      if(SymbolInfoTick(_Symbol,q) && q.time>0)
         PanelAdd("ราคาล่าสุดผ่านมา",PanelAge((long)(TimeTradeServer()-q.time)));
      PanelAdd("ผลตรวจโซน",LastGoodCycle==0 ? "ยังไม่ได้สแกน" : "รอข้อมูลใหม่");
      return;
   }
   if(TimeCurrent()<NextAllowed)
   {
      PanelAdd("พักก่อนรับ setup ใหม่","",1);
      PanelAdd("รับใหม่ได้เวลา",TimeToString(NextAllowed,TIME_MINUTES|TIME_SECONDS)); return;
   }
   if(EnableM1ZoneSignals)
   {
      if(pending>=0)
      {
         FastZone w=FastZones[pending];
         PanelAdd("รอ M1 ยืนยัน "+Dir(w.zone.side),"",1);
         PanelAdd("แตะโซนแล้ว · ยังไม่ใช่ Entry","",2);
         PanelAdd("โซน "+FrameName(w.zone.frame),Price(w.zone.low)+"–"+Price(w.zone.high),0,w.zone.name);
         PanelAdd("Trigger",Price(w.trigger));
         PanelAdd("ยืนยันก่อน",TimeToString(w.touched+FastSetupM1Bars*60,TIME_MINUTES|TIME_SECONDS));
         PanelAdd("บริบท H1",FastContext(w.zone.side));
      }
      else
      {
         PanelAdd(ArraySize(FastZones)==0 ? "ยังไม่มีโซนเข้าเกณฑ์" : (armed>0 ? "รอราคาแตะโซน" : "รอราคาปิดพ้นโซน"),"",1);
         PanelAdd(armed>0 ? "แตะโซน → M1 ยืนยัน → แผนพร้อม" : "เตรียมโซนก่อนเริ่ม setup ใหม่","",2);
         PanelAdd("โซนพร้อมติดตาม",IntegerToString(armed)+" / "+IntegerToString(ArraySize(FastZones)));
         PanelAdd("บริบท H1",Latest[1].valid ? Dir(Latest[1].dir) : "—");
      }
   }
   else
   {
      title=Stage==WAIT_ZONE ? "รอ M5 แตะโซนและ Sweep" :
            (Stage==WAIT_M5_CHOCH ? "รอ M5 CHoCH" : (Stage==WAIT_M1_BREAK ? "รอ M1 BOS / CHoCH" : "รอ M1 Retest"));
      PanelAdd(title,"",1); PanelAdd("โหมด Strict Sweep","",2);
      if(Stage!=WAIT_ZONE) { PanelAdd("ฝั่ง setup",Dir(SetupDir)); PanelAdd("หมดเวลารอ",TS(Expiry)); }
   }
   if(SignalID!="") PanelAdd("แผนก่อนหน้า","สิ้นสุดแล้ว",2,LastPlan+" | "+Status);
}

void PanelDetailRows()
{
   PanelAdd("สถานะต้นทาง","",1);
   for(int f=0;f<5;f++)
   {
      string state=FrameStatus[f];
      if(state=="WAIT_SCAN" || state=="CHECK_CHARTS") state="ยังไม่ได้ตรวจ";
      else if(Latest[f].valid)
         state=Dir(Latest[f].dir)+" "+Latest[f].kind+(DataHealth!="LIVE" || !Primed ? " (ข้อมูลเดิม)" : "");
      PanelAdd(FrameName(f),state,0,FrameDetail[f]+" | scan_ms="+IntegerToString((long)FrameMs[f])+" cache_ms="+FrameAge(f));
   }
   PanelAdd("Strict Sweep",EnumToString(Stage),0,Status);
   if(EnableZoneTracker && ShowZoneTracker)
      PanelAdd("Zone Observer",WatchHealth+" · Observe only",0,WatchLast);
   PanelAdd("M1 สแกนล่าสุด",TS(LastScannedM1));
   if(ShowDiagnostics)
   {
      PanelAdd("M5 ตรวจโซนล่าสุด",TS(ZoneCheckBar),0,ZoneDetail);
      PanelAdd("ผล Entry ล่าสุด",LastDecision,0,LastDecisionTooltip);
      PanelAdd("ต้นทางล่าสุด",LastSourceDetail,0,LastSourceTooltip);
   }
   PanelAdd("เหตุผล",DataHealth,2,Status+" | "+FastStatus);
}

void Dashboard()
{
   if(!OwnObjects || Pfx=="") return;
   long cw=0,ch=0; ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0,cw); ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0,ch);
   if(cw<160 || ch<85) { ObjectsDeleteAll(0,Pfx+"ui_"); PanelOldRows=0; return; }
   int width=(int)MathMin(PanelWidth,cw-16);
   int x=(int)MathMax(8,MathMin(PanelX,cw-width-8));
   int dpi=(int)TerminalInfoInteger(TERMINAL_SCREEN_DPI); if(dpi<72) dpi=96;
   int line=(int)MathCeil(PanelFontSize*dpi/72.0)+8;
   PanelButtonHeight=line+6;
   int header=PanelButtonHeight+12,footer=PanelButtonHeight+12;
   int minimum=header+line+10;
   if(ch<minimum+16) { ObjectsDeleteAll(0,Pfx+"ui_"); PanelOldRows=0; return; }
   int y=(int)MathMax(8,MathMin(PanelY,ch-minimum-8));
   ArrayResize(PanelLeft,0); ArrayResize(PanelRight,0); ArrayResize(PanelStyle,0); ArrayResize(PanelTips,0);
   PanelAdd(PanelHealthText(),"",2,"DataHealth="+DataHealth+" | "+Status);
   if(!PanelCollapsed)
   { if(PanelDetails) PanelDetailRows(); else PanelMainRows(); }
   int available=(int)ch-y-8;
   int count=ArraySize(PanelLeft),limit=(available-header-(PanelCollapsed ? 10 : footer))/line;
   bool cropped=count>limit;
   count=MathMax(1,MathMin(count,limit));
   if(cropped && count>2) { PanelLeft[count-1]="ขยายกราฟเพื่อดูข้อมูลครบ"; PanelRight[count-1]=""; PanelStyle[count-1]=2; }
   int height=MathMin(available,header+count*line+(PanelCollapsed ? 10 : footer));
   string bg=Pfx+"ui_bg";
   if(ObjectFind(0,bg)<0) ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,width); ObjectSetInteger(0,bg,OBJPROP_YSIZE,height);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,PanelBackground); ObjectSetInteger(0,bg,OBJPROP_COLOR,PanelRule);
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT); ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,bg,OBJPROP_ZORDER,0);
   int buttonwidth=MathMin(width-24,MathMax(54,line*3));
   PanelLabel("title",x+12,y+8,"SMC + SR | v1.11",PanelText,PanelFontSize+1,width-buttonwidth-38,false,_Symbol+" | "+(EnableM1ZoneSignals ? "M1 Zone Confirm" : "Strict Sweep"));
   PanelButton("collapse",x+width-buttonwidth-10,y+6,buttonwidth,PanelCollapsed ? "ขยาย" : "ย่อ");
   for(int i=0;i<count;i++)
   {
      int font=PanelFontSize;
      color ink=PanelText;
      if(PanelStyle[i]==2) ink=PanelMuted;
      if(PanelStyle[i]==1) font++;
      if(PanelStyle[i]==3) { ink=PanelBuy; font++; }
      if(PanelStyle[i]==4) { ink=PanelSell; font++; }
      if(i==0) ink=DataHealth=="LIVE" && Primed ? PanelBuy : (DataHealth=="DISCONNECTED" || DataHealth=="CLOCK_ERROR" ? PanelSell : PanelWarning);
      string id="row_"+IntegerToString(i);
      int rowy=y+header+i*line;
      bool paired=PanelRight[i]!="";
      int leftwidth=paired ? (width-28)*43/100 : width-24;
      PanelLabel(id+"_left",x+12,rowy,PanelLeft[i],ink,font,leftwidth,false,PanelTips[i]);
      if(paired) PanelLabel(id+"_right",x+width-12,rowy,PanelRight[i],ink,font,(width-28)*57/100,true,PanelTips[i]);
      else ObjectDelete(0,Pfx+"ui_"+id+"_right");
   }
   for(int i=count;i<PanelOldRows;i++)
   { ObjectDelete(0,Pfx+"ui_row_"+IntegerToString(i)+"_left"); ObjectDelete(0,Pfx+"ui_row_"+IntegerToString(i)+"_right"); }
   PanelOldRows=count;
   if(!PanelCollapsed && height>=header+count*line+footer)
   {
      int footy=y+height-footer+4;
      int detailswidth=MathMin(width-24,MathMax(92,line*5));
      PanelButton("details",x+12,footy,detailswidth,PanelDetails ? "กลับหน้าหลัก" : "รายละเอียด");
      string last=LastScannedM1>0 ? TimeToString(LastScannedM1,TIME_MINUTES) : "—";
      int scanwidth=width-36-detailswidth;
      if(scanwidth>=100)
         PanelLabel("scan",x+width-12,footy+4,"M1 ล่าสุด "+last,PanelMuted,PanelFontSize,scanwidth,true,"Last M1 scan="+TS(LastScannedM1)+" | quote monitoring only; no orders");
      else ObjectDelete(0,Pfx+"ui_scan");
   }
   else { ObjectDelete(0,Pfx+"ui_details"); ObjectDelete(0,Pfx+"ui_scan"); }
   ChartRedraw();
}

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(!OwnObjects) return;
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam==Pfx+"ui_collapse") PanelCollapsed=!PanelCollapsed;
      else if(sparam==Pfx+"ui_details") PanelDetails=!PanelDetails;
      else return;
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false); Dashboard();
   }
   else if(id==CHARTEVENT_CHART_CHANGE) Dashboard();
}


void Level(string tag,double price,color col)
{
   string n=Pfx+"plan_"+tag;
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,n,OBJPROP_PRICE,price);
   ObjectSetInteger(0,n,OBJPROP_COLOR,col);
   ObjectSetInteger(0,n,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetString(0,n,OBJPROP_TEXT,tag+" "+Price(price));
   ObjectSetString(0,n,OBJPROP_TOOLTIP,tag+" "+Price(price));
}

// --- v1.11 diagnostics: never authorize, extend or resurrect a setup. ---
string FrameName(int f)
{
   string s=EnumToString(Frames[f]); StringReplace(s,"PERIOD_",""); return s;
}
string FrameAge(int f)
{
   if(!FrameCached[f] || GetTickCount64()<CachedAt[f]) return "N/A";
   return IntegerToString((long)(GetTickCount64()-CachedAt[f]));
}
string Field(string name,string key)
{
   int p=StringFind(name,key);
   if(p<0) return "UNKNOWN";
   string value=StringSubstr(name,p+StringLen(key));
   int comma=StringFind(value,","); if(comma>=0) value=StringSubstr(value,0,comma);
   StringTrimLeft(value); StringTrimRight(value); return value;
}
string ZoneInfo(Zone &z)
{
   return "tf="+FrameName(z.frame)+" name="+z.name+" start="+TS(z.start)+
          " side="+Dir(z.side)+" low="+Price(z.low)+" high="+Price(z.high)+
          " strength="+Field(z.name,"Strength=")+" tests="+Field(z.name,"Test Count=");
}
void DiagnosticWrite(int handle,string row)
{
   if(handle==INVALID_HANDLE) return;
   if(FileWriteString(handle,row+"\r\n")==0) Print("SMC MTF: diagnostics write failed ",GetLastError());
   FileFlush(handle);
}
string DiagnosticPrefix(string model,string setup,datetime closed)
{
   return CSV("1")+","+CSV(WatchSession)+","+CSV(IntegerToString(++DiagnosticSeq))+","+
          CSV(TS(TimeTradeServer()))+","+CSV(_Symbol)+","+CSV(IntegerToString(SnapshotSerial))+","+
          CSV(model)+","+CSV(setup)+","+CSV(TS(closed));
}
void RecordSource(string model,string setup,string zone_id,string reason,string old_info,string new_info,datetime closed)
{
   string detail="model="+model+" setup_id="+setup+" zone_id="+zone_id+" reason="+reason+
      " old={"+old_info+"} new={"+new_info+"} snapshot="+IntegerToString(SnapshotSerial)+
      " detected_at="+TS(TimeTradeServer())+" M15_age_ms="+FrameAge(2);
   Log("SOURCE_DETAIL",detail);
   DiagnosticWrite(SourcesCSV,DiagnosticPrefix(model,setup,closed)+","+CSV(zone_id)+","+
      CSV(reason)+","+CSV(old_info)+","+CSV(new_info)+","+CSV(FrameAge(2)));
   LastSourceDetail=reason+" | "+zone_id; LastSourceTooltip=detail;
}
// Called only inside the existing rectangle scan; invalid/ineligible sources remain visible to diagnostics.
void CaptureRawZone(Zone &z,bool eligible,string exclusion,bool read_ok)
{
   if(z.frame!=2) return;
   RawZone r; r.zone=z; r.eligible=eligible; r.exclusion=exclusion; r.read_ok=read_ok;
   int n=ArraySize(RawZones); ArrayResize(RawZones,n+1); RawZones[n]=r;
   if(!read_ok) RawZoneReadOK=false;
}
string SourceDifference(Zone &old,string &current)
{
   current="NONE";
   if(!FrameCached[2] || !RawZoneReadOK) return "SCAN_INCOMPLETE";
   int exact=-1,candidates=0;
   for(int i=0;i<ArraySize(RawZones);i++)
   {
      Zone z=RawZones[i].zone;
      if(WatchKey(z)==WatchKey(old)) { exact=i; break; }
   }
   if(exact>=0)
   {
      RawZone r=RawZones[exact];
      current=ZoneInfo(r.zone)+" eligible="+Pass(r.eligible)+" excluded="+r.exclusion;
      if(!r.read_ok) return "SCAN_INCOMPLETE";
      if(MathAbs(r.zone.low-old.low)>TickSize*0.1 || MathAbs(r.zone.high-old.high)>TickSize*0.1)
         return "BOUNDS_CHANGED";
      if(!r.eligible) return "ELIGIBILITY_CHANGED";
      return r.zone.name!=old.name ? "METADATA_CHANGED" : "UNCHANGED";
   }
   for(int i=0;i<ArraySize(RawZones);i++)
   {
      Zone z=RawZones[i].zone;
      if(!RawZones[i].read_ok || z.frame!=old.frame || z.side!=old.side || z.start!=old.start ||
         MathAbs(z.low-old.low)>TickSize*0.1 || MathAbs(z.high-old.high)>TickSize*0.1) continue;
      if(candidates==0) current="";
      current+=(candidates>0 ? " || " : "")+ZoneInfo(z)+" eligible="+Pass(RawZones[i].eligible);
      candidates++;
   }
   if(candidates>1) return "AMBIGUOUS_MATCH";
   if(candidates==1) return "POSSIBLE_RENAME";
   return "SOURCE_NOT_FOUND";
}
string DiagnoseZone(Zone &z,string model,string setup,string zone_id,datetime closed)
{
   string current; string reason=SourceDifference(z,current);
   RecordSource(model,setup,zone_id,reason,ZoneInfo(z),current,closed);
   return reason;
}
void DiagnoseStructure(string model,string setup,string name,datetime closed,double price,int dir,string kind)
{
   if(name=="") return;
   string old="scope=STRUCTURE name="+name+" closed="+TS(closed)+" level="+Price(price)+
              " direction="+Dir(dir)+" kind="+kind;
   string current="not in accepted mapped events; object deletion NOT established";
   for(int i=0;i<ArraySize(Events);i++)
      if(Events[i].name==name)
      { current="name="+name+" closed="+TS(Events[i].closed)+" level="+Price(Events[i].price)+
                " direction="+Dir(Events[i].dir)+" kind="+Events[i].kind; break; }
   RecordSource(model,setup,"--","SOURCE_STRUCTURE_CHANGED",old,current,closed);
}
// Preserve first-seen times only for currently mapped signatures. No historical backfill.
void RefreshSeenEvents()
{
   // Only events in the maximum setup horizon can qualify for new entries.
   // Keep diagnostic work bounded; an overflow only marks timing as unavailable.
   datetime cutoff=TimeTradeServer()-(SetupExpiryM5Bars+ZoneObserveBars)*300-RetestExpiryM1Bars*60-900;
   EventSeen next[];
   int n=0;
   for(int i=0;i<ArraySize(Events);i++)
   {
      if(Events[i].closed<cutoff) continue;
      if(n>=1024) break;
      ArrayResize(next,n+1);
      next[n].event=Events[i]; next[n].seen=TimeTradeServer();
      for(int j=0;j<ArraySize(SeenEvents);j++)
         if(SeenEvents[j].event.name==Events[i].name && SeenEvents[j].event.kind==Events[i].kind &&
            SeenEvents[j].event.dir==Events[i].dir && SeenEvents[j].event.closed==Events[i].closed &&
            SeenEvents[j].event.price==Events[i].price)
         { next[n].seen=SeenEvents[j].seen; break; }
      n++;
   }
   ArrayResize(SeenEvents,n);
   for(int i=0;i<n;i++) SeenEvents[i]=next[i];
}

string StructureTiming(StructureEvent &e)
{
   datetime seen=0;
   for(int i=0;i<ArraySize(SeenEvents);i++)
      if(SeenEvents[i].event.name==e.name && SeenEvents[i].event.closed==e.closed &&
         SeenEvents[i].event.price==e.price && SeenEvents[i].event.kind==e.kind &&
         SeenEvents[i].event.dir==e.dir) { seen=SeenEvents[i].seen; break; }
   int f=Starts(e.name,"3|") ? 3 : 4;
   return " bar_closed_at="+TS(e.closed)+" first_seen_at="+(seen>0 ? TS(seen) : "N/A")+
      " detection_delay_s="+(seen>=e.closed ? IntegerToString((long)(seen-e.closed)) : "N/A")+
      " decision_at="+TS(TimeTradeServer())+" since_seen_s="+
      (seen>0 && TimeTradeServer()>=seen ? IntegerToString((long)(TimeTradeServer()-seen)) : "N/A")+
      " source_age_ms="+FrameAge(f);
}
void DiagnoseLate(string model,string setup,int frame,int dir,string kind,datetime after,datetime deadline)
{
   int chosen=-1;
   for(int i=0;i<ArraySize(Events);i++)
      if(Events[i].valid && Starts(Events[i].name,IntegerToString(frame)+"|") && Events[i].dir==dir &&
         Events[i].closed>after && (kind=="" || Events[i].kind==kind) &&
         (chosen<0 || Events[i].closed>Events[chosen].closed)) chosen=i;
   if(chosen<0) return;
   StructureEvent e=Events[chosen];
   for(int i=0;i<ArraySize(SeenEvents);i++)
      if(SeenEvents[i].event.name==e.name && SeenEvents[i].event.kind==e.kind &&
         SeenEvents[i].event.closed==e.closed && SeenEvents[i].event.price==e.price &&
         SeenEvents[i].event.dir==e.dir && SeenEvents[i].seen>deadline)
      {
         Log("LATE_EVENT","model="+model+" setup_id="+setup+" deadline="+TS(deadline)+
             " reason="+(e.closed>deadline ? "CLOSED_AFTER_DEADLINE" : "SEEN_AFTER_DEADLINE")+
             " event="+e.name+StructureTiming(e)+"; candidate evidence only; no retrospective entry");
         return;
      }
}
// Same distance geometry as Obstacle/WatchRoom, with stable tie display and source evidence.
void FindObstacle(int dir,double entry,double pad,string skip_key,ObstacleInfo &o)
{
   o.found=false; o.inside=false; o.room=1e30; o.edge=0; o.pad=pad; o.ties="";
   o.frame=-1; o.name=""; o.low=0; o.high=0;
   for(int i=0;i<ArraySize(Zones);i++)
   {
      Zone z=Zones[i];
      if(z.frame>2 || z.side==dir || (skip_key!="" && WatchKey(z)==skip_key)) continue;
      bool inside=entry>=z.low && entry<=z.high;
      double edge=dir>0 ? z.low : z.high;
      double delta=dir*(edge-entry);
      if(!inside && delta<=0) continue;
      double room=inside ? 0 : MathMax(0.0,delta-pad);
      string key=WatchKey(z)+"|"+Price(z.low)+"|"+Price(z.high)+"|"+z.name;
      if(!o.found || room<o.room)
      { o.found=true; o.room=room; o.ties=key; o.key=key; o.inside=inside;
        o.frame=z.frame; o.name=z.name; o.low=z.low; o.high=z.high; o.edge=edge; }
      else if(room==o.room)
      {
         o.ties+=" || "+key;
         if((inside && !o.inside) || (inside==o.inside && StringCompare(key,o.key)<0))
         { o.key=key; o.inside=inside; o.frame=z.frame; o.name=z.name; o.low=z.low; o.high=z.high; o.edge=edge; }
      }
   }
}
void EvaluateEntry(int dir,double entry,double stop,double spread,double trigger,double atr,
                   string skip_key,EntryDecision &d)
{
   d.entry=entry; d.stop=stop; d.risk=dir*(entry-stop); d.spread=spread;
   d.trigger=trigger; d.atr=atr; d.deviation=MathAbs(entry-trigger); d.allowed=atr*MaxEntryDeviationATR;
   d.required=TP2_R*d.risk; d.t1=0; d.t2=0; d.t3=0;
   FindObstacle(dir,entry,MathMax(TickSize,spread),skip_key,d.obstacle);
   d.code=PlanLevels(dir,entry,stop,d.obstacle.room,spread,trigger,atr,d.t1,d.t2,d.t3);
   d.reason="PASS";
   if(d.code==1) d.reason=d.risk<=0 ? "INVALID_STOP" : (d.risk<2*TickSize ? "RISK_TOO_SMALL" : "SPREAD_TOO_HIGH");
   if(d.code==2) d.reason="ENTRY_DEVIATION";
   if(d.code==3) d.reason=d.obstacle.inside ? "ENTRY_INSIDE_OPPOSING_ZONE" : "INSUFFICIENT_ROOM_TP2";
   if(d.code==4) d.reason="TARGET_ROUNDING";
   d.gates="stop="+Pass(d.risk>0)+" risk="+Pass(d.risk>=2*TickSize)+
      " spread="+(d.risk>0 ? Pass(spread/d.risk<=MaxSpreadToRisk) : "N/A")+
      " deviation="+Pass(d.deviation<=d.allowed)+
      " room="+(d.risk>0 ? Pass(d.obstacle.room>=d.required) : "N/A")+
      " rounding="+(d.code==0 ? "PASS" : (d.code==4 ? "FAIL" : "N/A"));
}
void RecordEntry(string model,string setup,datetime closed,MqlTick &tick,EntryDecision &d)
{
   string room=d.obstacle.found ? Price(d.obstacle.room) : "N/A";
   string room_r=d.obstacle.found && d.risk>0 ? DoubleToString(d.obstacle.room/d.risk,2) : "N/A";
   string source=d.obstacle.found ? FrameName(d.obstacle.frame)+" "+d.obstacle.name : "NONE";
   string required=d.risk>0 ? Price(d.required) : "N/A";
   string shortfall=d.risk>0 && d.obstacle.found ? Price(MathMax(0.0,d.required-d.obstacle.room)) : "N/A";
   string info="model="+model+" setup_id="+setup+" reason="+d.reason+" code="+IntegerToString(d.code)+
      " entry="+Price(d.entry)+" SL="+Price(d.stop)+" risk="+Price(d.risk)+" spread="+Price(d.spread)+
      " trigger_close="+Price(d.trigger)+" ATR="+Price(d.atr)+" deviation="+Price(d.deviation)+
      " allowed_deviation="+Price(d.allowed)+" room="+room+" room_R="+room_r+" required="+required+
      " shortfall="+shortfall+" obstacle="+source+" range="+Price(d.obstacle.low)+".."+Price(d.obstacle.high)+
      " pad="+Price(d.obstacle.pad)+" ties="+d.obstacle.ties+" gates={"+d.gates+"}"+
      " quote_time_msc="+IntegerToString(tick.time_msc)+" snapshot="+IntegerToString(SnapshotSerial);
   Log("ENTRY_CHECK",info);
   DiagnosticWrite(DecisionsCSV,DiagnosticPrefix(model,setup,closed)+","+CSV(d.reason)+","+
      CSV(IntegerToString(d.code))+","+CSV(Exact(d.entry))+","+CSV(Exact(d.stop))+","+CSV(Exact(d.risk))+","+
      CSV(Exact(d.spread))+","+CSV(Exact(d.trigger))+","+CSV(Exact(d.atr))+","+CSV(Exact(d.deviation))+","+
      CSV(Exact(d.allowed))+","+CSV(d.obstacle.found ? Exact(d.obstacle.room) : "N/A")+","+
      CSV(d.obstacle.found && d.risk>0 ? Exact(d.obstacle.room/d.risk) : "N/A")+","+
      CSV(d.risk>0 ? Exact(d.required) : "N/A")+","+
      CSV(d.risk>0 && d.obstacle.found ? Exact(MathMax(0.0,d.required-d.obstacle.room)) : "N/A")+","+
      CSV(source)+","+CSV(d.obstacle.found ? Price(d.obstacle.low) : "N/A")+","+
      CSV(d.obstacle.found ? Price(d.obstacle.high) : "N/A")+","+CSV(Exact(d.obstacle.pad))+","+
      CSV(d.obstacle.ties)+","+CSV(d.gates)+","+CSV(IntegerToString(tick.time_msc))+","+
      CSV(d.obstacle.found ? FrameAge(d.obstacle.frame) : "N/A"));
   LastDecision=model+" "+d.reason;
   LastDecisionRoom="Room "+room_r+"R / need "+DoubleToString(TP2_R,2)+"R | short "+shortfall;
   LastDecisionSource=source; LastDecisionTooltip=info;
}

// Nearest opposing H4/H1/M15 zone's near edge. Entry INSIDE such a zone blocks.
double Obstacle(int dir,double entry,double pad)
{
   double dist=1e30;
   for(int i=0;i<ArraySize(Zones);i++)
   {
      Zone z=Zones[i];
      if(z.frame>2 || z.side==dir) continue;
      if(entry>=z.low && entry<=z.high) return 0;
      double edge=dir>0 ? z.low : z.high;
      double delta=dir*(edge-entry);
      if(delta>0) dist=MathMin(dist,MathMax(0,delta-pad));
   }
   return dist;
}

// Pure plan calculation; return code 0=valid, 1=risk, 2=deviation,
// 3=HTF obstacle, 4=tick-rounding room. Separate for deterministic tests.
int PlanLevels(int dir,double entry,double stop,double room,double spread,
               double triggerClose,double atr,double &t1,double &t2,double &t3)
{
   double risk=dir*(entry-stop);
   if(risk<2*TickSize || spread/risk>MaxSpreadToRisk)
      return 1;
   if(MathAbs(entry-triggerClose)>atr*MaxEntryDeviationATR) return 2;
   if(room<TP2_R*risk)
      return 3;
   double finalR=MathMin(TP3_R,room/risk);
   t1=dir>0 ? Up(entry+TP1_R*risk) : Down(entry-TP1_R*risk);
   t2=dir>0 ? Up(entry+TP2_R*risk) : Down(entry-TP2_R*risk);
   // Round final target inward so it does not cross the obstacle buffer.
   t3=dir>0 ? Down(entry+finalR*risk) : Up(entry-finalR*risk);
   if(dir*(t3-t2)<0) return 4;
   return 0;
}

void Issue(MqlRates &bar,MqlTick &tick,double atr)
{
   double entry=SetupDir>0 ? tick.ask : tick.bid;
   double spread=tick.ask-tick.bid;
   EntryDecision decision; EvaluateEntry(SetupDir,entry,Stop,spread,bar.close,atr,"",decision);
   int code=decision.code;
   double t1=decision.t1,t2=decision.t2,t3=decision.t3;
   if(code!=0)
   {
      string reasons[4]={"spread/risk too high or invalid stop","price moved from trigger close",
                         "opposing HTF zone before TP2","insufficient room after tick rounding"};
      RecordEntry("STRICT_SWEEP",StrictSetupID,bar.time+60,tick,decision);
      ResetSetup("SKIP: "+reasons[code-1]); return;
   }
   Entry=entry; SL=Stop; ActiveDir=SetupDir; TP1=t1; TP2=t2; TP3=t3;
   Active=true; ReachedTP=0; ActiveModel="STRICT_SWEEP"; ActiveSince=TimeCurrent();
   SignalID=IntegerToString((long)(bar.time+60));
   LastPlan=Dir(ActiveDir)+" | Entry "+Price(Entry)+" | "+TS(TimeCurrent());
   Level("ENTRY",Entry,clrWhite); Level("SL",SL,clrTomato);
   Level("TP1",TP1,clrLimeGreen); Level("TP2",TP2,clrAqua); Level("TP3",TP3,clrDeepSkyBlue);
   string arrow=Pfx+"signal_"+SignalID;
   ObjectCreate(0,arrow,OBJ_ARROW,0,TimeCurrent(),Entry);
   ObjectSetInteger(0,arrow,OBJPROP_ARROWCODE,ActiveDir>0 ? 233 : 234);
   ObjectSetInteger(0,arrow,OBJPROP_COLOR,ActiveDir>0 ? clrLimeGreen : clrTomato);
   ObjectSetInteger(0,arrow,OBJPROP_WIDTH,2);
   string msg=_Symbol+" "+LastPlan+" | SL "+Price(SL)+" | TP1 "+Price(TP1)+
              " | TP2 "+Price(TP2)+" | TP3 "+Price(TP3);
   RecordEntry("STRICT_SWEEP",StrictSetupID,bar.time+60,tick,decision);
   Log("SIGNAL",msg+" | zone="+SetupZone.name+" | M5="+ConfirmName+" | M1="+BreakName);
   if(PopupAlerts) Alert(msg);
   if(PushAlerts && !SendNotification(msg)) Print("Push notification failed: ",GetLastError());
   ResetSetup("SIGNAL ACTIVE");
}

void Monitor(MqlTick &tick)
{
   if(!Active) return;
   int cooldown=ActiveModel=="M1_ZONE_CONFIRM" ? FastCooldownM1Bars : CooldownM1Bars;
   double exitQuote=ActiveDir>0 ? tick.bid : tick.ask;
   if(ActiveDir*(exitQuote-SL)<=0)
   {
      Active=false; NextAllowed=TimeCurrent()+cooldown*60;
      Status="SL observed (quote monitoring only)"; Log("SL_OBSERVED",SignalID); return;
   }
   int reached=ActiveDir*(exitQuote-TP3)>=0 ? 3 :
              (ActiveDir*(exitQuote-TP2)>=0 ? 2 : (ActiveDir*(exitQuote-TP1)>=0 ? 1 : 0));
   if(reached>ReachedTP)
   {
      ReachedTP=reached; Log("TP_OBSERVED",SignalID+" TP"+IntegerToString(reached));
   }
   Status="SIGNAL ACTIVE | TP reached="+IntegerToString(ReachedTP);
   if(reached==3)
   { Active=false; NextAllowed=TimeCurrent()+cooldown*60; Status="Final TP observed"; return; }
   if(ActiveModel=="M1_ZONE_CONFIRM" && TimeCurrent()>=ActiveSince+FastPlanM1Bars*60)
   {
      Active=false; NextAllowed=TimeCurrent()+cooldown*60;
      Status="Fast plan display expired; no trade execution"; Log("FAST_PLAN_EXPIRED",SignalID); return;
   }
}

void Process(MqlRates &m1[],MqlRates &m5[],MqlTick &tick,bool newM5)
{
   int bias=Latest[1].dir;
   double atr=ATR(m5),spread=tick.ask-tick.bid;
   if(atr<=0) { ResetSetup("WAIT: invalid ATR"); return; }
   if(RequireH4Alignment && Latest[0].dir!=bias)
   { ResetSetup("WAIT: H4/H1 conflict"); return; }
   if(Active) return;
   if(TimeCurrent()<NextAllowed) { Status="Cooldown"; return; }
   if(Stage!=WAIT_ZONE)
   {
      if(bias!=SetupDir) { ResetSetup("RESET: H1 bias changed"); return; }
      if(TimeCurrent()>Expiry)
      {
         if(Stage==WAIT_M5_CHOCH) DiagnoseLate("STRICT_SWEEP",StrictSetupID,3,SetupDir,"CHoCH",SweepClosed,Expiry);
         if(Stage==WAIT_M1_BREAK) DiagnoseLate("STRICT_SWEEP",StrictSetupID,4,SetupDir,"",ConfirmClosed,Expiry);
         ResetSetup("RESET: setup expired"); return;
      }
      if(!SameZone(SetupZone))
      { DiagnoseZone(SetupZone,"STRICT_SWEEP",StrictSetupID,"--",m1[0].time+60);
        ResetSetup("RESET: source zone changed/disappeared"); return; }
      if(!EventStillPresent(ConfirmName,ConfirmClosed,ConfirmPrice,SetupDir) ||
         !EventStillPresent(BreakName,BreakClosed,BreakPrice,SetupDir))
      {
         if(!EventStillPresent(ConfirmName,ConfirmClosed,ConfirmPrice,SetupDir))
            DiagnoseStructure("STRICT_SWEEP",StrictSetupID,ConfirmName,ConfirmClosed,ConfirmPrice,SetupDir,"CHoCH");
         if(!EventStillPresent(BreakName,BreakClosed,BreakPrice,SetupDir))
            DiagnoseStructure("STRICT_SWEEP",StrictSetupID,BreakName,BreakClosed,BreakPrice,SetupDir,"BOS/CHoCH");
         ResetSetup("RESET: source structure changed/disappeared"); return;
      }
      if(SetupDir>0 ? m1[0].low<=Stop : m1[0].high>=Stop)
      { ResetSetup("RESET: stop invalidated before entry"); return; }
      if(newM5 && (SetupDir>0 ? m5[0].close<SetupZone.low : m5[0].close>SetupZone.high))
      { ResetSetup("RESET: M15 zone invalidated by M5 close"); return; }
   }
   if(Stage==WAIT_ZONE)
   {
      Status="WAIT: next closed M5; last="+ZoneReason;
      if(!newM5) return;
      double pivot=0;
      int selected=-1;
      if(!EvaluateZone(m5,bias,selected,pivot))
      { Status="WAIT_ZONE: "+ZoneReason; return; }
      SetupZone=Zones[selected]; SetupDir=bias;
      StrictSetupID=WatchSession+"-STRICT-"+IntegerToString((long)(m5[0].time+300));
      double pad=MathMax(atr*SL_ATR_Buffer,MathMax(spread*SL_Spread_Multiple,2*TickSize));
      Stop=bias>0 ? Down(m5[0].low-pad) : Up(m5[0].high+pad);
      SweepClosed=m5[0].time+300; Expiry=TimeCurrent()+SetupExpiryM5Bars*300;
      Stage=WAIT_M5_CHOCH; Status="WAIT: M5 CHoCH after sweep";
      Log("SWEEP",Dir(bias)+" zone="+SetupZone.name+" stop="+Price(Stop));
      return;
   }
   StructureEvent e;
   if(Stage==WAIT_M5_CHOCH)
   {
      Status="WAIT: M5 CHoCH after sweep";
      if(EventAfter(3,SetupDir,SweepClosed,"CHoCH",e))
      {
         ConfirmClosed=e.closed; ConfirmName=e.name; ConfirmPrice=e.price;
         Stage=WAIT_M1_BREAK; Status="WAIT: new M1 BOS/CHoCH";
         Log("M5_CONFIRM",e.name+" "+TS(e.closed)+StructureTiming(e));
      }
      // A delayed M5 event can arrive with a fresh, later M1 break in this scan.
      // Consume that break now; the retest still needs a subsequent closed bar.
      if(Stage!=WAIT_M1_BREAK) return;
   }
   if(Stage==WAIT_M1_BREAK)
   {
      Status="WAIT: new M1 BOS/CHoCH";
      if(EventAfter(4,SetupDir,ConfirmClosed,"",e) && e.closed==m1[0].time+60)
      {
         BreakPrice=e.price; BreakClosed=e.closed; BreakName=e.name;
         Stage=WAIT_M1_RETEST; Status="WAIT: M1 retest "+Price(BreakPrice);
         Log("M1_BREAK",e.name+" level="+Price(BreakPrice)+StructureTiming(e));
      }
      return;
   }
   if(Stage==WAIT_M1_RETEST)
   {
      Status="WAIT: M1 retest "+Price(BreakPrice);
      if(m1[0].time+60>BreakClosed+RetestExpiryM1Bars*60)
      { ResetSetup("RESET: retest expired"); return; }
      if(m1[0].time<BreakClosed) return;
      double tol=MathMax(TickSize,atr*Retest_ATR_Tolerance);
      bool touch=m1[0].low<=BreakPrice+tol && m1[0].high>=BreakPrice-tol;
      bool reject=SetupDir>0 ? (m1[0].close>BreakPrice && m1[0].close>m1[0].open) :
                              (m1[0].close<BreakPrice && m1[0].close<m1[0].open);
      if(touch && reject) Issue(m1[0],tick,atr);
   }
}

// --- Observational zone engine. All timestamps below are candle-close times. ---
string WatchKey(Zone &z)
{
   // Test Count / Strength text may change without changing the zone itself.
   int space=StringFind(z.name," ");
   string base=space<0 ? z.name : StringSubstr(z.name,0,space);
   return IntegerToString(z.frame)+"|"+base+"|"+IntegerToString(z.side)+"|"+IntegerToString((long)z.start);
}

void WatchLog(ZoneWatch &w,string event,datetime closed,string reason)
{
   string info="zone_id="+w.id+" setup_id="+w.setup+" source="+w.zone.name+
      " range="+Price(w.zone.low)+".."+Price(w.zone.high)+" bar_closed="+TS(closed)+
      " state="+w.state+" model="+w.model+" direction="+Dir(w.direction)+
      " gate="+w.gate+" buffer="+Price(w.buffer)+" tolerance="+Price(w.tolerance)+
      " reason="+reason+" OBSERVE_ONLY";
   w.last_event=event; w.last_event_closed=closed; w.last_event_seen=TimeTradeServer();
   info+=" detected_at="+TS(w.last_event_seen)+" snapshot="+IntegerToString(SnapshotSerial)+" M15_age_ms="+FrameAge(2);
   Log(event,info);
   WatchLast=event+" "+w.id+" @ "+TS(closed);
}

void WatchEnd(ZoneWatch &w,string state,datetime closed,string reason)
{
   if(w.terminal) return;
   if(reason=="OBSERVATION_EXPIRED" && w.direction!=0)
   {
      if(w.confirmed==0) DiagnoseLate(w.model,w.setup,3,w.direction,w.model=="ZONE_REJECTION" ? "CHoCH" : "BOS",
                                     w.model=="ZONE_REJECTION" ? w.reaction : w.breakout-1,w.started+ZoneObserveBars*300);
      else if(w.broken==0) DiagnoseLate(w.model,w.setup,4,w.direction,"",w.confirmed,w.started+ZoneObserveBars*300);
   }
   w.state=state; w.gate=reason; w.terminal=true;
   WatchLog(w,"ZONE_END",closed,reason);
   if(w.started>0) WatchLastTerminal=w.id+" "+reason+" @ "+TS(TimeTradeServer());
}

bool WatchApproach(ZoneWatch &w,double close)
{
   return w.zone.side>0 ? close>w.zone.high+w.buffer : close<w.zone.low-w.buffer;
}

bool WatchFarSide(ZoneWatch &w,double close)
{
   return w.zone.side>0 ? close<w.zone.low-w.buffer : close>w.zone.high+w.buffer;
}

void WatchReset(ZoneWatch &w)
{
   w.last_event=""; w.last_event_closed=0; w.last_event_seen=0;
   w.setup="--"; w.state="WAIT_TOUCH"; w.model="--"; w.gate="WAIT_APPROACH";
   w.started=0; w.reaction=0; w.breakout=0; w.retest=0; w.confirmed=0; w.broken=0;
   w.armed=0; w.extreme=0; w.stop=0; w.direction=0; w.terminal=false;
   w.confirm_name=""; w.break_name=""; w.confirm_price=0; w.break_price=0;
}

void WatchInvalidate(string reason)
{
   for(int i=0;i<ArraySize(Watches);i++)
      if(Watches[i].started>0 && !Watches[i].terminal)
         WatchEnd(Watches[i],"DATA_RESET",TimeCurrent(),reason);
   ArrayResize(Watches,0); WatchM5=0; WatchHealth="WAIT_SYNC";
}

void LoseSync(string reason)
{
   // Log even in WAIT_ZONE; deduplicate repeated timer failures.
   if(Primed || SyncReason!=reason)
      Log("SYNC_LOST","reason="+reason+" last_M1="+TS(LastM1)+" stage="+EnumToString(Stage));
   if(Primed || ArraySize(Watches)>0) WatchInvalidate(reason);
   ArrayResize(SeenEvents,0); FastClear(reason); LastFastClosed=0;
   Primed=false; SyncReason=reason;
}

void SyncWatches(datetime head,MqlRates &last,double atr,double spread)
{
   if(!EnableZoneTracker) return;
   int count=0;
   for(int j=0;j<ArraySize(Zones);j++) if(Zones[j].frame==2) count++;
   if(count>MaxTrackedZones)
   {
      if(WatchHealth!="ZONE_LIMIT")
      { WatchInvalidate("ZONE_LIMIT"); Log("ZONE_LIMIT","M15 count="+IntegerToString(count)); }
      WatchHealth="ZONE_LIMIT"; return;
   }
   for(int i=ArraySize(Watches)-1;i>=0;i--)
   {
      bool found=false;
      for(int j=0;j<ArraySize(Zones);j++)
         if(Zones[j].frame==2 && WatchKey(Zones[j])==WatchKey(Watches[i].zone) &&
            MathAbs(Zones[j].low-Watches[i].zone.low)<=TickSize*0.1 &&
            MathAbs(Zones[j].high-Watches[i].zone.high)<=TickSize*0.1)
         {
            if(Watches[i].metadata_name!=Zones[j].name)
            {
               Zone previous=Watches[i].zone; previous.name=Watches[i].metadata_name;
               RecordSource(Watches[i].model,Watches[i].setup,Watches[i].id,"METADATA_CHANGED",
                            ZoneInfo(previous),ZoneInfo(Zones[j]),head);
               Watches[i].metadata_name=Zones[j].name;
            }
            found=true; break;
         }
      if(found) continue;
      Zone previous=Watches[i].zone; previous.name=Watches[i].metadata_name;
      string cause=DiagnoseZone(previous,Watches[i].model,Watches[i].setup,Watches[i].id,head);
      bool incomplete=cause=="SCAN_INCOMPLETE";
      WatchLog(Watches[i],incomplete ? "ZONE_DATA_RESET" : "ZONE_SOURCE_CHANGED",head,"see SOURCE_DETAIL; frozen snapshot retired");
      if(!Watches[i].terminal) WatchEnd(Watches[i],incomplete ? "DATA_RESET" : "SOURCE_CHANGED",head,
                                       incomplete ? "SCAN_INCOMPLETE" : "SOURCE_CHANGED");
      for(int k=i;k<ArraySize(Watches)-1;k++) Watches[k]=Watches[k+1];
      ArrayResize(Watches,ArraySize(Watches)-1);
   }
   for(int j=0;j<ArraySize(Zones);j++)
   {
      if(Zones[j].frame!=2) continue;
      bool found=false;
      for(int i=0;i<ArraySize(Watches);i++)
         if(WatchKey(Watches[i].zone)==WatchKey(Zones[j])) { found=true; break; }
      if(found) continue;
      ZoneWatch w; w.zone=Zones[j]; w.metadata_name=Zones[j].name; w.id="Z"+IntegerToString(++WatchSerial);
      WatchReset(w); w.seen=head; w.last_m5=last.time; w.last_m1=0;
      w.buffer=MathMax(2*TickSize,atr*ZoneConfirmATR);
      w.tolerance=MathMax(TickSize,atr*ZoneRetestATR);
      w.pad=MathMax(atr*SL_ATR_Buffer,MathMax(spread*SL_Spread_Multiple,2*TickSize));
      // A newly discovered zone must not explain an already closed candle.
      if(WatchApproach(w,last.close)) { w.armed=head; w.gate="WAIT_TOUCH"; }
      int n=ArraySize(Watches); ArrayResize(Watches,n+1); Watches[n]=w;
      WatchLog(Watches[n],"ZONE_REGISTER",head,"new snapshot; no historical backfill");
   }
   WatchHealth="LIVE";
}

void WatchBar(ZoneWatch &w,MqlRates &bar,double atr,double spread)
{
   if(bar.time<=w.last_m5) return;
   w.last_m5=bar.time;
   datetime closed=bar.time+300;
   if(w.terminal)
   {
      // Require a fresh outside close, then a later touch; never re-use this bar.
      if(WatchApproach(w,bar.close))
      { WatchReset(w); w.armed=closed; w.gate="WAIT_TOUCH"; WatchLog(w,"ZONE_REARM",closed,"fresh outside close"); }
      return;
   }
   bool touch=bar.high>=w.zone.low && bar.low<=w.zone.high;
   if(w.started==0)
   {
      if(w.armed==0)
      {
         if(WatchApproach(w,bar.close)) { w.armed=closed; w.gate="WAIT_TOUCH"; }
         return;
      }
      if(bar.time<w.armed || bar.time<w.seen) return;
      if(!touch)
      {
         if(WatchFarSide(w,bar.close)) WatchEnd(w,"GAP_CROSS",closed,"crossed without a recorded touch");
         return;
      }
      w.setup=WatchSession+"-"+IntegerToString(++WatchSetupSerial);
      w.started=closed; w.state="IN_ZONE"; w.gate="WAIT_M5_CLOSE";
      w.buffer=MathMax(2*TickSize,atr*ZoneConfirmATR);
      w.tolerance=MathMax(TickSize,atr*ZoneRetestATR);
      w.pad=MathMax(atr*SL_ATR_Buffer,MathMax(spread*SL_Spread_Multiple,2*TickSize));
      w.extreme=w.zone.side>0 ? bar.low : bar.high;
      WatchLog(w,"ZONE_TOUCH",closed,"M5 range overlaps frozen zone");
   }
   if(closed-w.started>=ZoneObserveBars*300)
   { WatchEnd(w,"EXPIRED",closed,"OBSERVATION_EXPIRED"); return; }
   if(w.state=="IN_ZONE")
   {
      if(closed-w.started>=ZoneReactionBars*300)
      { WatchEnd(w,"EXPIRED",closed,"REACTION_EXPIRED"); return; }
      w.extreme=w.zone.side>0 ? MathMin(w.extreme,bar.low) : MathMax(w.extreme,bar.high);
      if(WatchFarSide(w,bar.close))
      {
         w.state="BREAKOUT_CONFIRMED"; w.model="BREAKOUT_RETEST"; w.direction=-w.zone.side;
         w.breakout=closed; w.gate="WAIT_M5_BOS"; w.extreme=0;
         WatchLog(w,"ZONE_BREAKOUT",closed,"M5 close beyond far edge; BOS not assumed");
         w.state="WAIT_RETEST";
      }
      else if(WatchApproach(w,bar.close))
      {
         w.state="REJECTION_CONFIRMED"; w.model="ZONE_REJECTION"; w.direction=w.zone.side;
         w.reaction=closed; w.gate="WAIT_M5_CHOCH";
         w.stop=w.direction>0 ? Down(w.extreme-w.pad) : Up(w.extreme+w.pad);
         WatchLog(w,"ZONE_REJECTION",closed,"M5 close beyond approach edge");
      }
      return; // Breakout bar cannot double as its own retest.
   }
   if(w.model=="ZONE_REJECTION")
   {
      if(WatchFarSide(w,bar.close)) WatchEnd(w,"REJECTION_FAILED",closed,"M5 closed through far edge");
      return;
   }
   if(w.model!="BREAKOUT_RETEST") return;
   double edge=w.direction>0 ? w.zone.high : w.zone.low;
   if(w.direction*(bar.close-edge)<-w.buffer)
   { WatchEnd(w,"BREAKOUT_FAILED",closed,"M5 close back inside beyond buffer"); return; }
   if(w.retest>0) return;
   if(closed-w.breakout>ZoneRetestBars*300)
   { WatchEnd(w,"EXPIRED",closed,"ZONE_RETEST_EXPIRED"); return; }
   if(bar.time<w.breakout) return;
   bool edge_touch=bar.low<=edge+w.tolerance && bar.high>=edge-w.tolerance;
   if(!edge_touch) return;
   double x=w.direction>0 ? bar.low : bar.high;
   w.extreme=w.extreme==0 ? x : (w.direction>0 ? MathMin(w.extreme,x) : MathMax(w.extreme,x));
   if(w.direction*(bar.close-edge)>w.buffer)
   {
      w.retest=closed; w.state="RETEST_HELD";
      w.stop=w.direction>0 ? Down(w.extreme-w.pad) : Up(w.extreme+w.pad);
      WatchLog(w,"ZONE_RETEST_HELD",closed,"later M5 retested edge and closed outside");
   }
}

bool WatchStructure(ZoneWatch &w,int frame,datetime earliest,datetime latest,string kind,StructureEvent &out)
{
   out.valid=false;
   for(int i=0;i<ArraySize(Events);i++)
   {
      StructureEvent e=Events[i];
      if(!e.valid || !Starts(e.name,IntegerToString(frame)+"|") || e.dir!=w.direction ||
         e.closed<earliest || e.closed>latest || (kind!="" && e.kind!=kind)) continue;
      // For zone breakouts, BOS must break a level at/beyond the breached edge.
      if(frame==3 && w.model=="BREAKOUT_RETEST")
      {
         double edge=w.direction>0 ? w.zone.high : w.zone.low;
         if(w.direction*(e.price-edge)<-w.buffer) continue;
      }
      if(!out.valid || e.closed<out.closed) out=e;
   }
   return out.valid;
}

void WatchGate(ZoneWatch &w,string gate,datetime closed)
{
   if(w.gate==gate) return;
   w.gate=gate; WatchLog(w,"OBS_GATE",closed,gate);
}

bool WatchConfirmationPresent(ZoneWatch &w)
{
   if(w.confirm_name=="") return true;
   string kind=w.model=="ZONE_REJECTION" ? "CHoCH" : "BOS";
   for(int i=0;i<ArraySize(Events);i++)
      if(Events[i].valid && Events[i].name==w.confirm_name && Events[i].kind==kind &&
         Events[i].closed==w.confirmed && Events[i].dir==w.direction &&
         MathAbs(Events[i].price-w.confirm_price)<=TickSize) return true;
   return false;
}

double WatchRoom(ZoneWatch &w,double entry,double pad)
{
   double room=1e30;
   for(int i=0;i<ArraySize(Zones);i++)
   {
      Zone z=Zones[i];
      if(z.frame>2 || z.side==w.direction) continue;
      // The confirmed broken source zone is a retest level, not its own obstacle.
      if(w.model=="BREAKOUT_RETEST" && WatchKey(z)==WatchKey(w.zone)) continue;
      if(entry>=z.low && entry<=z.high) return 0;
      double edge=w.direction>0 ? z.low : z.high;
      double distance=w.direction*(edge-entry);
      if(distance>0) room=MathMin(room,MathMax(0.0,distance-pad));
   }
   return room;
}

void WatchEntry(ZoneWatch &w,MqlRates &m1,MqlRates &m5,MqlTick &tick,double atr)
{
   datetime closed=m1.time+60;
   if(w.started==0 || w.terminal || w.direction==0 || m1.time<=w.last_m1) return;
   w.last_m1=m1.time;
   if(closed-w.started>=ZoneObserveBars*300)
   { WatchEnd(w,"EXPIRED",closed,"OBSERVATION_EXPIRED"); return; }
   if(!WatchConfirmationPresent(w) ||
      !EventStillPresent(w.break_name,w.broken,w.break_price,w.direction))
   {
      if(!WatchConfirmationPresent(w))
         DiagnoseStructure(w.model,w.setup,w.confirm_name,w.confirmed,w.confirm_price,w.direction,
                           w.model=="ZONE_REJECTION" ? "CHoCH" : "BOS");
      if(!EventStillPresent(w.break_name,w.broken,w.break_price,w.direction))
         DiagnoseStructure(w.model,w.setup,w.break_name,w.broken,w.break_price,w.direction,"BOS/CHoCH");
      WatchEnd(w,"SOURCE_CHANGED",closed,"SOURCE_STRUCTURE_CHANGED"); return;
   }
   if(w.stop>0 && m1.time>=(w.model=="ZONE_REJECTION" ? w.reaction : w.retest) &&
      (w.direction>0 ? m1.low<=w.stop : m1.high>=w.stop))
   { WatchEnd(w,"INVALIDATED",closed,"STOP_BEFORE_ENTRY"); return; }
   StructureEvent e;
   if(w.confirmed==0)
   {
      datetime after=w.model=="ZONE_REJECTION" ? w.reaction+1 : w.breakout;
      string kind=w.model=="ZONE_REJECTION" ? "CHoCH" : "BOS";
      if(!WatchStructure(w,3,after,m5.time+300,kind,e))
      { WatchGate(w,"WAIT_M5_"+kind,closed); return; }
      w.confirmed=e.closed; w.confirm_name=e.name; w.confirm_price=e.price;
      WatchLog(w,"OBS_M5_CONFIRM",closed,"structure_closed="+TS(e.closed)+" "+kind+" level="+Price(e.price)+StructureTiming(e));
   }
   if(w.model=="BREAKOUT_RETEST" && w.retest==0)
   { WatchGate(w,"WAIT_ZONE_RETEST",closed); return; }
   // Once structurally qualified, reject this episode if direction is disallowed.
   if(Latest[1].dir!=w.direction || (RequireH4Alignment && Latest[0].dir!=w.direction))
   { WatchEnd(w,"ENTRY_BLOCKED",closed,"HTF_DIRECTION_CONFLICT"); return; }
   datetime ready=w.confirmed;
   if(w.retest>ready) ready=w.retest;
   if(w.broken==0)
   {
      if(!WatchStructure(w,4,closed,closed,"",e) || e.closed<=ready)
      { WatchGate(w,"WAIT_M1_BREAK",closed); return; }
      w.broken=e.closed; w.break_name=e.name; w.break_price=e.price;
      WatchGate(w,"WAIT_M1_RETEST",closed);
      WatchLog(w,"OBS_M1_BREAK",closed,"level="+Price(e.price)+StructureTiming(e)); return;
   }
   if(closed>w.broken+RetestExpiryM1Bars*60)
   { WatchEnd(w,"EXPIRED",closed,"M1_RETEST_EXPIRED"); return; }
   if(m1.time<w.broken) return;
   double tol=MathMax(TickSize,atr*Retest_ATR_Tolerance);
   bool touch=m1.low<=w.break_price+tol && m1.high>=w.break_price-tol;
   bool reject=w.direction>0 ? (m1.close>w.break_price && m1.close>m1.open) :
                               (m1.close<w.break_price && m1.close<m1.open);
   if(!touch || !reject) return;
   // Logs and other zone observers may have consumed time since the scan gate.
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<tick.bid ||
      TimeTradeServer()-tick.time>MaxQuoteAgeSeconds || tick.time>TimeTradeServer()+5)
   { WatchEnd(w,"DATA_RESET",closed,"QUOTE_INVALID_AT_OBSERVATION"); return; }
   if(Active || TimeCurrent()<NextAllowed)
   { WatchEnd(w,"ENTRY_BLOCKED",closed,Active ? "STRICT_PLAN_ACTIVE" : "STRICT_COOLDOWN"); return; }
   double entry=w.direction>0 ? tick.ask : tick.bid;
   double spread=tick.ask-tick.bid;
   EntryDecision decision;
   EvaluateEntry(w.direction,entry,w.stop,spread,m1.close,atr,
                 w.model=="BREAKOUT_RETEST" ? WatchKey(w.zone) : "",decision);
   int code=decision.code;
   double t1=decision.t1,t2=decision.t2,t3=decision.t3;
   RecordEntry(w.model,w.setup,closed,tick,decision);
   if(code!=0)
   {
      string reasons[4]={"SPREAD_OR_STOP","ENTRY_DEVIATION","HTF_OBSTACLE","TARGET_ROUNDING"};
      WatchEnd(w,"ENTRY_BLOCKED",closed,reasons[code-1]); return;
   }
   w.state="OBS_PLAN_READY"; w.gate="OBSERVE_ONLY"; w.terminal=true;
   WatchLog(w,"OBS_PLAN",closed,"entry="+Price(entry)+" SL="+Price(w.stop)+
            " TP1="+Price(t1)+" TP2="+Price(t2)+" TP3="+Price(t3)+"; hypothetical; no signal issued");
}

void ObserveZones(MqlRates &m1[],MqlRates &m5[],MqlTick &tick,bool newM5)
{
   if(!EnableZoneTracker) return;
   double atr=ATR(m5);
   if(atr<=0) { WatchInvalidate("INVALID_ATR"); return; }
   if(newM5 && WatchM5>0 && m5[0].time-WatchM5!=300) WatchInvalidate("M5_DATA_GAP");
   // Sync against previous M5 when this bar has just closed. Newly found zones
   // still carry 'seen' = current head and cannot backfill the closed bar.
   SyncWatches(m1[0].time+60,m5[1],atr,tick.ask-tick.bid);
   if(WatchHealth!="LIVE") return;
   for(int i=0;i<ArraySize(Watches);i++)
   {
      if(newM5) WatchBar(Watches[i],m5[0],atr,tick.ask-tick.bid);
      WatchEntry(Watches[i],m1[0],m5[0],tick,atr);
   }
   if(newM5) WatchM5=m5[0].time;
}

datetime WatchDeadline(ZoneWatch &w)
{
   if(w.started==0 || w.terminal) return 0;
   datetime deadline=w.started+ZoneObserveBars*300;
   if(w.state=="IN_ZONE") deadline=(datetime)MathMin((long)deadline,(long)(w.started+ZoneReactionBars*300));
   // Retest limits use >, so these are the last allowed close times.
   if(w.model=="BREAKOUT_RETEST" && w.retest==0 && w.breakout>0)
      deadline=(datetime)MathMin((long)deadline,(long)(w.breakout+ZoneRetestBars*300));
   if(w.broken>0) deadline=(datetime)MathMin((long)deadline,(long)(w.broken+RetestExpiryM1Bars*60));
   return deadline;
}
// M1 price-action lane. Uses only previously known zones and confirmed OHLC pivots.
bool FastPivotAt(MqlRates &r[],int k,int side,int left,int right)
{
   if(k<right || k+left>=ArraySize(r)) return false;
   double p=side>0 ? r[k].low : r[k].high;
   for(int j=1;j<=left;j++) if(side>0 ? r[k+j].low<=p : r[k+j].high>=p) return false;
   for(int j=1;j<=right;j++) if(side>0 ? r[k-j].low<=p : r[k-j].high>=p) return false;
   return true;
}
string FastContext(int dir)
{
   if(!Latest[1].valid) return "H1_UNKNOWN";
   return Latest[1].dir==dir ? "WITH_H1" : "COUNTER_H1";
}
void FastLog(FastZone &w,string event,datetime closed,string reason)
{
   FastStatus=event+" "+Dir(w.zone.side)+" "+FrameName(w.zone.frame)+" | "+reason;
   Log(event,"model=M1_ZONE_CONFIRM setup_id="+w.id+" source="+w.zone.name+
       " tf="+FrameName(w.zone.frame)+" side="+Dir(w.zone.side)+" range="+Price(w.zone.low)+".."+Price(w.zone.high)+
       " bar_closed="+TS(closed)+" detected_at="+TS(TimeTradeServer())+" trigger="+Price(w.trigger)+
       " frozen="+IntegerToString((int)w.detached)+" context="+FastContext(w.zone.side)+" reason="+reason);
}
void FastEnd(FastZone &w,datetime closed,string reason)
{
   if(w.terminal) return;
   w.terminal=true; FastLog(w,"FAST_END",closed,reason);
}
void FastClear(string reason)
{
   for(int i=0;i<ArraySize(FastZones);i++)
      if(FastZones[i].touched>0 && !FastZones[i].terminal) FastEnd(FastZones[i],TimeCurrent(),reason);
   ArrayResize(FastZones,0); FastStatus="WAIT_SYNC: "+reason;
}
bool FastSame(Zone &a,Zone &b)
{
   return a.frame==b.frame && a.side==b.side && a.start==b.start &&
          MathAbs(a.low-b.low)<=TickSize*0.1 && MathAbs(a.high-b.high)<=TickSize*0.1;
}
bool FastOutside(FastZone &w,double close)
{
   return w.zone.side>0 ? close>w.zone.high+TickSize : close<w.zone.low-TickSize;
}
void FastAdd(Zone &z,datetime head,double previous_close,bool swing)
{
   for(int i=0;i<ArraySize(FastZones);i++)
   {
      // A derived pivot keeps its initial width even when ATR changes.
      bool same=swing ? (FastZones[i].swing && FastZones[i].zone.start==z.start && FastZones[i].zone.side==z.side) :
                       (!FastZones[i].swing && FastSame(FastZones[i].zone,z));
      if(!same) continue;
      FastZones[i].present=true;
      return;
   }
   int n=ArraySize(FastZones);
   if(n>=128) { FastCapacity=true; return; }
   FastZone w; w.zone=z; w.id=WatchSession+"-F"+IntegerToString(++FastSerial);
   w.since=head; w.armed=0; w.touched=0; w.trigger=0; w.extreme=0; w.stop=0;
   w.present=true; w.detached=false; w.swing=swing; w.previewed=false; w.terminal=false;
   if(FastOutside(w,previous_close)) w.armed=head;
   ArrayResize(FastZones,n+1); FastZones[n]=w;
}
void FastSync(MqlRates &m1[],double atr,datetime head)
{
   FastCapacity=false;
   for(int i=0;i<ArraySize(FastZones);i++) FastZones[i].present=false;
   for(int i=0;i<ArraySize(Zones);i++)
      if(Zones[i].start<=head && (Zones[i].frame==2 || (FastUseM5Zones && Zones[i].frame==3)))
         FastAdd(Zones[i],head,m1[0].close,false);
   if(FastUseM1Swings)
   {
      double width=MathMax(2*TickSize,atr*FastSwingWidthATR);
      for(int side=-1;side<=1;side+=2)
      {
         int found=0;
         for(int k=2;k<MathMin(ArraySize(m1)-2,60) && found<2;k++)
         {
            if(!FastPivotAt(m1,k,side,2,2)) continue;
            Zone z; z.frame=4; z.side=side; z.start=m1[k].time;
            z.name="M1_SWING_"+Dir(side)+"_"+IntegerToString((long)z.start);
            double level=side>0 ? m1[k].low : m1[k].high;
            z.low=Down(level-width); z.high=Up(level+width);
            FastAdd(z,head,m1[0].close,true); found++;
         }
      }
   }
   if(FastCapacity) { FastClear("ZONE_CAPACITY"); return; }
   for(int i=ArraySize(FastZones)-1;i>=0;i--)
   {
      if(FastZones[i].present) continue;
      // The source may redraw on the same close that first touched its previously known bounds.
      // Preserve that bar's opportunity before retiring an idle watch; never use a newly seen zone retrospectively.
      bool just_touched=FastZones[i].touched==0 && FastZones[i].armed>0 &&
         m1[0].time>=FastZones[i].since && m1[0].time>=FastZones[i].armed &&
         m1[0].high>=FastZones[i].zone.low && m1[0].low<=FastZones[i].zone.high;
      if((FastZones[i].touched>0 || just_touched) && !FastZones[i].terminal)
      {
         if(!FastZones[i].detached)
         { FastZones[i].detached=true; FastLog(FastZones[i],"FAST_SOURCE_FROZEN",head,"source changed; keep original bounds until original deadline"); }
         continue;
      }
      for(int j=i;j<ArraySize(FastZones)-1;j++) FastZones[j]=FastZones[j+1];
      ArrayResize(FastZones,ArraySize(FastZones)-1);
   }
}
bool FastMicroTrigger(MqlRates &m1[],int dir,double &level)
{
   // The newest eligible pivot is confirmed by the bar BEFORE the touch bar.
   for(int k=2;k<MathMin(ArraySize(m1)-2,40);k++)
   {
      if(!FastPivotAt(m1,k,-dir,2,1)) continue;
      double p=dir>0 ? m1[k].high : m1[k].low;
      if(dir*(p-m1[1].close)<=0) continue; // already broken before this setup
      level=p; return true;
   }
   level=0; return false;
}
void FastMark(string id,string label,datetime at,double price,int code,color col)
{
   string n=Pfx+"fast_"+id+"_"+label;
   if(ObjectFind(0,n)>=0) return;
   ObjectCreate(0,n,OBJ_ARROW,0,at,price);
   ObjectSetInteger(0,n,OBJPROP_ARROWCODE,code); ObjectSetInteger(0,n,OBJPROP_COLOR,col);
   ObjectSetInteger(0,n,OBJPROP_WIDTH,2);
   ObjectSetString(0,n,OBJPROP_TOOLTIP,label+" "+id+" @ "+TS(at)+" "+Price(price));
}
void FastPreview(MqlTick &tick)
{
   if(!EnableM1ZoneSignals || !Primed || DataHealth!="LIVE" || LastGoodCycle==0 ||
      GetTickCount64()-LastGoodCycle>75000 || iTime(_Symbol,PERIOD_M1,0)-LastScannedM1>60 || tick.bid<=0 || tick.ask<tick.bid ||
      TimeTradeServer()-tick.time>MaxQuoteAgeSeconds || tick.time>TimeTradeServer()+5) return;
   for(int i=0;i<ArraySize(FastZones);i++)
   {
      if(FastZones[i].terminal || FastZones[i].armed==0 || FastZones[i].previewed || FastZones[i].detached ||
         tick.time<FastZones[i].since || tick.bid<FastZones[i].zone.low || tick.bid>FastZones[i].zone.high) continue;
      FastZones[i].previewed=true;
      FastLog(FastZones[i],"FAST_TOUCH_PREVIEW",tick.time,"intrabar touch; NOT an entry; wait for closed M1");
      FastMark(FastZones[i].id,"TOUCH_ONLY",tick.time,tick.bid,159,clrYellow);
      if(FastTouchAlerts && PopupAlerts) Alert(_Symbol+" TOUCH ONLY "+FastZones[i].zone.name+"; wait for M1 confirmation");
   }
}
// Confirmed M1 condition; no labels or future pivot endpoints are needed.
bool FastConfirmed(FastZone &w,MqlRates &bar,double atr)
{
   double range=bar.high-bar.low;
   if(range<=0 || MathAbs(bar.close-bar.open)/range<FastMinBodyFraction) return false;
   int dir=w.zone.side;
   double buffer=MathMax(TickSize,atr*FastBreakATR);
   return dir*(bar.close-bar.open)>0 && dir*(bar.close-w.trigger)>buffer &&
          (dir>0 ? bar.close>w.zone.high+buffer : bar.close<w.zone.low-buffer);
}
void FastIssue(FastZone &w,MqlRates &bar,double atr)
{
   if(!SnapshotFresh() || iTime(_Symbol,PERIOD_M1,0)!=bar.time+60)
   { FastEnd(w,bar.time+60,"DATA_CHANGED_BEFORE_ENTRY"); return; }
   MqlTick q;
   if(!SymbolInfoTick(_Symbol,q) || q.bid<=0 || q.ask<q.bid ||
      TimeTradeServer()-q.time>MaxQuoteAgeSeconds || q.time>TimeTradeServer()+5)
   { FastEnd(w,bar.time+60,"QUOTE_INVALID"); return; }
   if(Active || TimeCurrent()<NextAllowed)
   { FastEnd(w,bar.time+60,Active ? "PLAN_ACTIVE" : "COOLDOWN"); return; }
   if(!FastAllowCounterH1 && Latest[1].dir!=w.zone.side)
   { FastEnd(w,bar.time+60,"H1_CONFLICT"); return; }
   int dir=w.zone.side;
   double spread=q.ask-q.bid;
   double pad=MathMax(atr*SL_ATR_Buffer,MathMax(spread*SL_Spread_Multiple,2*TickSize));
   w.stop=dir>0 ? Down(w.extreme-pad) : Up(w.extreme+pad);
   EntryDecision d;
   EvaluateEntry(dir,dir>0 ? q.ask : q.bid,w.stop,spread,bar.close,atr,"",d);
   if(d.code!=0)
   { RecordEntry("M1_ZONE_CONFIRM",w.id,bar.time+60,q,d); FastEnd(w,bar.time+60,d.reason); return; }
   Entry=d.entry; SL=d.stop; TP1=d.t1; TP2=d.t2; TP3=d.t3; ActiveDir=dir;
   Active=true; ReachedTP=0; ActiveModel="M1_ZONE_CONFIRM"; ActiveSince=TimeCurrent();
   ResetSetup("M1 SIGNAL ACTIVE");
   SignalID=w.id; LastPlan="M1 "+Dir(dir)+" "+FastContext(dir)+" | Entry "+Price(Entry);
   Level("ENTRY",Entry,clrWhite); Level("SL",SL,clrTomato); Level("TP1",TP1,clrLimeGreen);
   Level("TP2",TP2,clrAqua); Level("TP3",TP3,clrDeepSkyBlue);
   FastMark(w.id,"ENTRY_"+Dir(dir),TimeCurrent(),Entry,dir>0 ? 233 : 234,dir>0 ? clrLimeGreen : clrTomato);
   RecordEntry("M1_ZONE_CONFIRM",w.id,bar.time+60,q,d);
   FastEnd(w,bar.time+60,"SIGNAL_ISSUED");
   string msg=_Symbol+" "+LastPlan+" SL "+Price(SL)+" TP1 "+Price(TP1)+" TP2 "+Price(TP2)+" TP3 "+Price(TP3);
   Log("FAST_SIGNAL",msg+" setup_id="+w.id+" source="+w.zone.name+" trigger="+Price(w.trigger));
   if(PopupAlerts) Alert(msg);
   if(PushAlerts && !SendNotification(msg)) Print("Push notification failed: ",GetLastError());
}
void FastProcess(MqlRates &m1[],double atr)
{
   if(!EnableM1ZoneSignals || FastCapacity || atr<=0 || ArraySize(m1)<8) return;
   MqlRates bar=m1[0]; datetime closed=bar.time+60;
   if(LastFastClosed==closed) return;
   LastFastClosed=closed;
   for(int i=0;i<ArraySize(FastZones);i++)
   {
      FastZone w=FastZones[i];
      if(w.terminal)
      {
         if(!w.detached && FastOutside(w,bar.close))
         {
            w.id=WatchSession+"-F"+IntegerToString(++FastSerial); w.touched=0; w.trigger=0; w.extreme=0;
            w.stop=0; w.terminal=false; w.previewed=false; w.armed=closed;
         }
         FastZones[i]=w; continue;
      }
      if(w.armed==0)
      { if(FastOutside(w,bar.close)) w.armed=closed; FastZones[i]=w; continue; }
      if(bar.time<w.since || bar.time<w.armed) continue;
      if(w.touched==0)
      {
         if(bar.high<w.zone.low || bar.low>w.zone.high) continue;
         w.touched=closed; w.extreme=w.zone.side>0 ? bar.low : bar.high;
         FastLog(w,"FAST_ZONE_TOUCH",closed,"closed M1 overlap; capture pre-touch micro pivot");
         if(!w.previewed) FastMark(w.id,"TOUCH_ONLY",closed,w.zone.side>0 ? bar.low : bar.high,159,clrYellow);
         w.previewed=true;
         if(!FastMicroTrigger(m1,w.zone.side,w.trigger))
         { FastEnd(w,closed,"NO_PRETOUCH_MICRO_PIVOT"); FastZones[i]=w; continue; }
         FastLog(w,"FAST_WAIT_M1_BREAK",closed,"close beyond frozen trigger and zone; no M5 CHoCH required");
      }
      if(closed-w.touched>=FastSetupM1Bars*60)
      { FastEnd(w,closed,"SETUP_EXPIRED"); FastZones[i]=w; continue; }
      double pad=MathMax(TickSize,atr*FastBreakATR);
      if(w.zone.side>0 ? bar.close<w.zone.low-pad : bar.close>w.zone.high+pad)
      { FastEnd(w,closed,"ZONE_BROKEN_WRONG_WAY"); FastZones[i]=w; continue; }
      w.extreme=w.zone.side>0 ? MathMin(w.extreme,bar.low) : MathMax(w.extreme,bar.high);
      if(FastConfirmed(w,bar,atr)) FastIssue(w,bar,atr);
      FastZones[i]=w;
   }
}
string FastSummary()
{
   if(DataHealth!="LIVE" || !Primed) return "WAIT_SYNC | "+DataHealth;
   if(Active) return "PLAN_ACTIVE | "+ActiveModel;
   if(TimeCurrent()<NextAllowed) return "COOLDOWN until "+TS(NextAllowed);
   int armed=0;
   for(int i=0;i<ArraySize(FastZones);i++)
   {
      FastZone w=FastZones[i];
      if(w.terminal) continue;
      if(w.touched>0)
         return "WAIT_M1_BREAK "+Dir(w.zone.side)+" "+FrameName(w.zone.frame)+
                " trigger="+Price(w.trigger)+" until "+TS(w.touched+FastSetupM1Bars*60);
      if(w.armed>0) armed++;
   }
   if(ArraySize(FastZones)==0) return "NO_ELIGIBLE_ZONE";
   return armed>0 ? "WAIT_ZONE_TOUCH | armed="+IntegerToString(armed) : "WAIT_APPROACH | need close outside zone first";
}
void OnTimer()
{
   if(Busy) return;
   Busy=true;
   TimerPulses++;
   ulong timer_start=GetTickCount64();
   datetime live_head=iTime(_Symbol,PERIOD_M1,0);
   if(LastGoodCycle==0 || GetTickCount64()-LastGoodCycle>75000 ||
      live_head<=0 || live_head-LastScannedM1>60) DataHealth="STALE";
   MqlTick tick;
   bool connected=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   bool quote_valid=SymbolInfoTick(_Symbol,tick) && tick.ask>0 && tick.bid>0 && tick.ask>=tick.bid;
   datetime quote_now=TimeTradeServer();
   string quote_health=QuoteHealth(connected,quote_valid,quote_now,quote_valid ? tick.time : 0,-1);
   if(quote_health=="STALE_QUOTE")
      quote_health=QuoteHealth(connected,quote_valid,quote_now,tick.time,QuoteSessionState(quote_now));
   if(quote_health!="FRESH")
   {
      DataHealth=quote_health; LoseSync(quote_health);
      ResetSetup("WAIT: "+quote_health); Dashboard(); Busy=false; return;
   }
   Monitor(tick);
   FastPreview(tick);
   if(LastChartsCheck==0 || GetTickCount64()-LastChartsCheck>=10000)
   {
      ChartSetReady=FindCharts(); LastChartsCheck=GetTickCount64();
   }
   if(!ChartSetReady)
   {
      string why=Status; LoseSync("SOURCE_MISSING: "+why); DataHealth="SOURCE_MISSING";
      for(int f=0;f<5;f++) { Latest[f].valid=false; FrameCached[f]=false; FrameStatus[f]="CHECK_CHARTS"; FrameDetail[f]=why; }
      ResetSetup(why); Dashboard(); Busy=false; return;
   }
   datetime head=iTime(_Symbol,PERIOD_M1,0);
   // Allow original indicators to calculate after a new minute begins.
   M1Clock=head<=0 ? "NO_HISTORY" : (TimeCurrent()<head+2 ? "WARMUP_2S" :
                                   (TimeCurrent()-head>90 ? "BAR_TIME_STALE" : "TIME_OK"));
   if(M1Clock!="TIME_OK")
   {
      if(M1Clock=="NO_HISTORY") { DataHealth="STALE_HISTORY"; LoseSync("M1_NO_HISTORY"); ResetSetup("WAIT: M1 history unavailable"); }
      else if(M1Clock=="BAR_TIME_STALE") { DataHealth="STALE_HISTORY"; LoseSync("M1_BAR_TIME_STALE"); ResetSetup("WAIT: stale M1 bar time"); }
      Dashboard(); Busy=false; return;
   }
   if(DataHealth=="STALE") { LoseSync("SCAN_AGE_OR_M1_GAP"); ResetSetup("WAIT: stale scan; re-sync required"); }
   if(Primed && head==LastM1) { Dashboard(); Busy=false; return; }
   if(GetTickCount64()<RetryAfter) { Dashboard(); Busy=false; return; }
   MqlRates m1[],m5[];
   if(!Rates(PERIOD_M1,m1) || !Rates(PERIOD_M5,m5))
   {
      DataHealth="STALE_HISTORY"; LoseSync("M1_M5_HISTORY"); RetryAfter=GetTickCount64()+10000;
      ResetSetup("WAIT: M1/M5 signal history (HistoryBars)"); Dashboard(); Busy=false; return;
   }
   if(!Snapshot())
   {
      Log("SCAN_REJECT",Status);
      DataHealth="STALE_SOURCE"; LoseSync("SNAPSHOT: "+Status); RetryAfter=GetTickCount64()+10000;
      string why=Status; ResetSetup(why); Dashboard(); Busy=false; return;
   }
   RetryAfter=0;
   RefreshSeenEvents(); // Included in the final cycle/quote freshness gate below.
   if(iTime(_Symbol,PERIOD_M1,0)!=head)
   { DataHealth="STALE_SCAN"; LoseSync("M1_BAR_CHANGED"); ResetSetup("WAIT: bar changed during scan"); Dashboard(); Busy=false; return; }
   // Re-read the quote AFTER synchronous chart calls. Never issue using the old quote.
   string reject="";
   if(!SnapshotFresh()) reject=SnapshotIssue;
   else if(iTime(_Symbol,PERIOD_M1,0)!=head) reject="M1_BAR_CHANGED";
   else if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0 || tick.ask<tick.bid)
      reject="INVALID_QUOTE";
   else if(GetTickCount64()-timer_start>(ulong)MaxCycleMs) reject="CYCLE_TIMEOUT";
   else if(TimeTradeServer()-tick.time>MaxQuoteAgeSeconds || tick.time>TimeTradeServer()+5)
      reject="STALE_QUOTE";
   if(reject!="")
   {
      Log("SCAN_REJECT",reject);
      DataHealth="STALE_SCAN"; LoseSync(reject); RetryAfter=GetTickCount64()+10000;
      ResetSetup("WAIT: "+reject+"; no entry"); Dashboard(); Busy=false; return;
   }
   SnapshotSerial++;
   LastScannedM1=head; LastGoodCycle=GetTickCount64(); DataHealth="LIVE";
   if(!Primed)
   {
      Primed=true; LastM1=head; LastM5=m5[0].time;
      Log("PRIME","M1_open="+TS(head)+" M5_closed="+TS(m5[0].time+300)+" reason="+SyncReason+"; waiting for new setup");
      WatchInvalidate("REPRIME");
      SyncWatches(head,m5[0],ATR(m5),tick.ask-tick.bid); WatchM5=m5[0].time;
      if(EnableM1ZoneSignals) { FastClear("PRIME_OR_GAP"); FastSync(m1,ATR(m1),head); LastFastClosed=head; }
      ResetSetup("READY: waiting for a new setup (no historical signals)");
      for(int f=0;f<5;f++)
         Log("MAPPED_STRUCTURE",EnumToString(Frames[f])+" "+Dir(Latest[f].dir)+" "+
             Latest[f].kind+" level="+Price(Latest[f].price)+" endpoint="+TS(Latest[f].candle));
      Dashboard(); Busy=false; return;
   }
   // After missing minutes, re-prime instead of inventing the event sequence.
   if(head-LastM1!=60)
   {
      Log("DATA_GAP","previous_M1="+TS(LastM1)+" current_M1="+TS(head));
      WatchInvalidate("M1_DATA_GAP");
      SyncWatches(head,m5[0],ATR(m5),tick.ask-tick.bid); WatchM5=m5[0].time;
      if(EnableM1ZoneSignals) { FastClear("PRIME_OR_GAP"); FastSync(m1,ATR(m1),head); LastFastClosed=head; }
      LastM1=head; LastM5=m5[0].time; ResetSetup("RESET: data gap; waiting for new setup");
      Dashboard(); Busy=false; return;
   }
   bool newM5=m5[0].time!=LastM5;
   LastM1=head; LastM5=m5[0].time;
   if(!Active) Process(m1,m5,tick,newM5);
   ObserveZones(m1,m5,tick,newM5);
   if(EnableM1ZoneSignals)
   {
      FastSync(m1,ATR(m1),head);
      FastProcess(m1,ATR(m1));
   }
   Dashboard(); Busy=false;
}

int OnInit()
{
   OwnObjects=false; Primed=false; Busy=false; Active=false;
   PanelCollapsed=PanelStartCollapsed; PanelDetails=false; PanelOldRows=0;
   OwnerKey=""; OwnerToken=0;
   ArrayResize(FastZones,0); FastSerial=0; FastCapacity=false; LastFastClosed=0;
   FastStatus="WAIT_SYNC"; ActiveSince=0; ActiveModel="STRICT_SWEEP";
   ArrayResize(RawZones,0); ArrayResize(SeenEvents,0); RawZoneReadOK=true;
   SnapshotSerial=0; DiagnosticSeq=0; StrictSetupID="--"; WatchSelected="";
   DecisionsCSV=INVALID_HANDLE; SourcesCSV=INVALID_HANDLE;
   LastDecision="No entry check yet"; LastDecisionRoom=""; LastDecisionSource=""; LastDecisionTooltip="";
   LastSourceDetail="No source change"; LastSourceTooltip=""; WatchLastTerminal="No terminal setup yet";
   ArrayResize(Watches,0); WatchSerial=0; WatchSetupSerial=0; WatchM5=0;
   WatchSession=IntegerToString((long)TimeLocal())+"-"+IntegerToString((long)GetTickCount64());
   WatchLast="No zone event yet"; WatchHealth=EnableZoneTracker ? "STARTING" : "DISABLED";
   SyncReason="INITIAL_START";
   Stage=WAIT_ZONE; LastM1=0; LastM5=0; NextAllowed=0;
   TimerPulses=0; LastScannedM1=0; M1Clock="STARTING";
   ZoneCheckBar=0; ZoneCheckBias=0; ZoneTotal=0; ZoneEligible=0; ZoneTouched=0; ZoneQualified=0;
   ZonePivotFound=false; ZoneBreach=false; ZoneReclaim=false; ZonePivot=0;
   ZoneReason="NOT_CHECKED"; ZoneRange="--"; ZoneDetail="No WAIT_ZONE evaluation yet";
   RetryAfter=0; LastChartsCheck=0; LastGoodCycle=0; ChartSetReady=false; DataHealth="STARTING";
   for(int f=0;f<5;f++)
   { FrameCached[f]=false; CachedBar[f]=0; CachedAt[f]=0; CachedChart[f]=-1; FrameMs[f]=0; }
   for(int f=0;f<5;f++)
   { Latest[f].valid=false; FrameStatus[f]="WAIT_SCAN"; FrameDetail[f]="Waiting for source scan"; LastFrameCode[f]=""; }
   ConfirmName=""; BreakName="";
   if(_Period!=PERIOD_M1) { Print("Attach SMC_SR_MTF_Signals to M1."); return INIT_PARAMETERS_INCORRECT; }
   if(FastSetupM1Bars<1 || FastSetupM1Bars>60 || FastCooldownM1Bars<0 || FastCooldownM1Bars>60 ||
      FastPlanM1Bars<1 || FastPlanM1Bars>240 || FastSwingWidthATR<=0 || FastSwingWidthATR>1 ||
      FastBreakATR<0 || FastBreakATR>1 || FastMinBodyFraction<=0 || FastMinBodyFraction>1)
      return INIT_PARAMETERS_INCORRECT;
   if(PanelFontSize<7 || PanelFontSize>14 || PanelWidth<240 || PanelWidth>640 || PanelX<0 || PanelY<0 || PanelFont=="") return INIT_PARAMETERS_INCORRECT;
   if(ZoneConfirmATR<0 || ZoneRetestATR<0 || ZoneReactionBars<1 || ZoneRetestBars<1 ||
      ZoneObserveBars<1 || ZoneReactionBars>100 || ZoneRetestBars>100 || ZoneObserveBars>200 ||
      MaxTrackedZones<1 || MaxTrackedZones>128) return INIT_PARAMETERS_INCORRECT;
   if(HTFCacheSeconds<60 || HTFCacheSeconds>900 || MaxFrameScanMs<100 ||
      MaxCycleMs<MaxFrameScanMs || MaxCycleMs>30000 || MaxQuoteAgeSeconds<1 || MaxQuoteAgeSeconds>60 ||
      PivotLeft<1 || PivotRight<1 || ATRPeriod<2 || HistoryBars<50 || HistoryBars>2000 ||
      StructureHistoryBars<50 || StructureHistoryBars>20000 ||
      HistoryBars<=PivotLeft+PivotRight+3 || HistoryBars<=ATRPeriod+1 ||
      SL_ATR_Buffer<0 || SL_Spread_Multiple<0 || Retest_ATR_Tolerance<0 ||
      SetupExpiryM5Bars<1 || RetestExpiryM1Bars<1 || CooldownM1Bars<0 ||
      TP1_R<=0 || TP2_R<=TP1_R || TP3_R<=TP2_R || MaxSpreadToRisk<=0 ||
      MaxEntryDeviationATR<=0 || SMCBullColor==SMCBearColor || MaxObjectsToScan<100)
      return INIT_PARAMETERS_INCORRECT;
   TickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(TickSize<=0) TickSize=_Point;
   Pfx="SMCSR_MTF_"+InstanceTag+"_";
   // Older versions have no ownership lock. Do not erase a live legacy instance's objects.
   for(int i=0;i<ChartIndicatorsTotal(0,0);i++)
   {
      string other=ChartIndicatorName(0,0,i);
      if(Starts(other,"SMC SR MTF Signals v1.") && other!="SMC SR MTF Signals v1.11 ["+InstanceTag+"]" &&
         StringFind(other,"["+InstanceTag+"]")>=0)
      { Print("Remove the older SMC MTF instance before adding v1.11."); return INIT_FAILED; }
   }
   // A saved chart can restore old labels. Temporary ownership survives only this terminal session.
   uint tag_hash=2166136261;
   for(int i=0;i<StringLen(InstanceTag);i++) tag_hash=(uint)((tag_hash^(uint)StringGetCharacter(InstanceTag,i))*(uint)16777619);
   OwnerKey="SMCSR_OWNER_"+IntegerToString(ChartID())+"_"+IntegerToString((long)tag_hash);
   if(!GlobalVariableTemp(OwnerKey) || !GlobalVariableSetOnCondition(OwnerKey,1.0,0.0))
   { Print("Another live instance owns this chart/tag. Remove that instance first."); return INIT_FAILED; }
   OwnerToken=1.0; OwnObjects=true;
   int recovered=ObjectsDeleteAll(0,Pfx);
   if(recovered>0) Print("Recovered old SMC MTF display objects; waiting for fresh data.");
   SetIndexBuffer(0,HiddenBuffer,INDICATOR_DATA);
   IndicatorSetString(INDICATOR_SHORTNAME,"SMC SR MTF Signals v1.11 ["+InstanceTag+"]");
   if(WriteAuditCSV)
   {
      AuditFile="SMC_MTF_Audit_"+IntegerToString((long)TimeLocal())+"_"+
                IntegerToString((long)GetTickCount64())+".csv";
      Audit=FileOpen(AuditFile,FILE_WRITE|FILE_TXT|FILE_ANSI,0,CP_UTF8);
      if(Audit!=INVALID_HANDLE) FileWriteString(Audit,"server_time,symbol,event,detail\r\n");
      else Print("Audit unavailable: ",GetLastError());
   }
   if(WriteAuditCSV && WriteDetailedCSV)
   {
      DecisionsFile="SMC_MTF_Decisions_"+WatchSession+".csv";
      SourcesFile="SMC_MTF_SourceChanges_"+WatchSession+".csv";
      DecisionsCSV=FileOpen(DecisionsFile,FILE_WRITE|FILE_TXT|FILE_ANSI,0,CP_UTF8);
      SourcesCSV=FileOpen(SourcesFile,FILE_WRITE|FILE_TXT|FILE_ANSI,0,CP_UTF8);
      string base="schema_version,run_id,event_seq,server_time,symbol,snapshot_id,model,setup_id,bar_closed";
      DiagnosticWrite(DecisionsCSV,base+",reason,code,entry,stop,risk,spread,trigger_close,atr,deviation,allowed_deviation,room,room_R,required_room,shortfall,obstacle,obstacle_low,obstacle_high,pad,ties,gates,quote_time_msc,obstacle_age_ms");
      DiagnosticWrite(SourcesCSV,base+",zone_id,reason,old_source,new_source,M15_age_ms");
   }
   if(!EventSetTimer(2)) return INIT_FAILED;
   Log("START","v1.11; closed-bar signals; bounded scans; HTF cache seconds="+IntegerToString(HTFCacheSeconds));
   Log("FAST_CONFIG","enabled="+IntegerToString((int)EnableM1ZoneSignals)+" confirmation=CLOSED_M1_MICRO_BREAK"+
       " M5_zones="+IntegerToString((int)FastUseM5Zones)+" M1_swings="+IntegerToString((int)FastUseM1Swings)+
       " counter_H1="+IntegerToString((int)FastAllowCounterH1)+" setup_M1_bars="+IntegerToString(FastSetupM1Bars));
   Log("ZONE_CONFIG","enabled="+IntegerToString((int)EnableZoneTracker)+" OBSERVE_ONLY confirm_ATR="+
       DoubleToString(ZoneConfirmATR,3)+" retest_ATR="+DoubleToString(ZoneRetestATR,3)+
       " reaction_bars="+IntegerToString(ZoneReactionBars)+" retest_bars="+IntegerToString(ZoneRetestBars)+
       " lifetime_bars="+IntegerToString(ZoneObserveBars));
   Log("DETAIL_STATUS","Decisions="+(DecisionsCSV!=INVALID_HANDLE ? DecisionsFile : "DISABLED_OR_UNAVAILABLE")+
       " Sources="+(SourcesCSV!=INVALID_HANDLE ? SourcesFile : "DISABLED_OR_UNAVAILABLE"));
   Log("AUDIT_STATUS",Audit!=INVALID_HANDLE ? AuditFile : "CSV disabled or unavailable; see Experts");
   Dashboard();
   return INIT_SUCCEEDED;
}

int OnCalculate(const int rates_total,const int prev_calculated,const int begin,const double &price[])
{
   if(prev_calculated==0) ArrayInitialize(HiddenBuffer,EMPTY_VALUE);
   if(OwnObjects && !Busy)
   {
      datetime head=iTime(_Symbol,PERIOD_M1,0);
      if(LastScannedM1>0 && head-LastScannedM1>60)
      {
         if(DataHealth=="LIVE" && Primed) { DataHealth="STALE_SCAN"; Dashboard(); }
      }
      else
      {
         MqlTick q;
         if(SymbolInfoTick(_Symbol,q)) FastPreview(q);
      }
   }
   return rates_total;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Log("STOP","deinit_reason="+IntegerToString(reason));
   if(Audit!=INVALID_HANDLE) { FileFlush(Audit); FileClose(Audit); Audit=INVALID_HANDLE; }
   if(DecisionsCSV!=INVALID_HANDLE) { FileFlush(DecisionsCSV); FileClose(DecisionsCSV); DecisionsCSV=INVALID_HANDLE; }
   if(SourcesCSV!=INVALID_HANDLE) { FileFlush(SourcesCSV); FileClose(SourcesCSV); SourcesCSV=INVALID_HANDLE; }
   if(OwnObjects && Pfx!="") ObjectsDeleteAll(0,Pfx);
   if(OwnObjects && OwnerToken!=0 && OwnerKey!="") GlobalVariableSetOnCondition(OwnerKey,0.0,OwnerToken);
}
