#property strict
#property version "1.10"
#property description "Research V1.10: M3 MA + RSI + wick, BB TP; assumptions are inputs."
#include <Trade/Trade.mqh>

enum ENUM_HN_RISK { RISK_PERCENT=0, VIDEO_BALANCE_STEP=1, FIXED_LOT=2 };
enum ENUM_HN_SL { FIXED_STOP=0, CLOSE_BAR_STOP=1 };
enum ENUM_HN_TOUCH { MA_REBOUND=0, BODY_NEAR_MA=1, CLOSE_NEAR_MA=2 };
enum ENUM_HN_DIRECTION { AUTO_DIRECTION=0, LONG_ONLY=1, SHORT_ONLY=2 };
enum ENUM_HN_ALIGN { STRICT_ALIGNMENT=0, NO_OPPOSING_TREND=1 };
enum ENUM_HN_SL_BASIS { SWING_STOP=0, SIGNAL_CANDLE_STOP=1, ATR_STOP=2, FIXED_DISTANCE_STOP=3 };
enum ENUM_HN_TP { RR_TARGET=0, BB_TARGET=1 };

input group "Identity / execution"
input ulong InpMagic=26100510;
input bool InpAllowLiveTrading=false; // tester only by default
input int InpMaxPositions=1;          // one position; no averaging
input int InpMaxSpreadPoints=500;     // points, NOT pips; broker-specific hypothesis
input int InpMaxSlippagePoints=20;
input double InpMarginUsePercent=80.0;
input string InpRunTag="video_ema";
input bool InpWriteCSV=true;
input bool InpWriteDecisionCSV=true;

input group "Lot calculation / explicit currency conversion"
input ENUM_HN_RISK InpRiskMode=VIDEO_BALANCE_STEP;
input double InpRiskPercent=1.0;
input double InpFixedLot=0.1;
input double InpMaxLot=10.0;
input double InpRoundTripCostPerLot=0.0;
input string InpStepCurrency="JPY";
input string InpBalanceLotSteps="0:0.1;10000:0.1;30000:0.2;50000:0.3;100000:0.5;150000:0.5;300000:0.7;500000:1.0;1000000:1.6";
input bool InpProportionalAboveLastStep=true;
input bool InpUseManualStepConversion=true;
input string InpConversionAccountCurrency="USD"; // guard against applying JPY/USD rate to EUR etc.
input double InpStepUnitsPerAccountUnit=150.0; // hypothetical JPY per USD, NOT current FX
input bool InpStopBelowFirstStep=false; // false: use first lot below first threshold

input group "Trend (closed bars; periods/types are hypotheses)"
input bool InpEnableLong=true;
input bool InpEnableShort=true;
input ENUM_HN_DIRECTION InpTrendMode=AUTO_DIRECTION;
input ENUM_HN_ALIGN InpTrendAlignment=STRICT_ALIGNMENT;
input bool InpUseD1Trend=false; // no longer mandatory
input bool InpUseH1Trend=true;
input bool InpUseH4Trend=true;
input int InpFastMA=20; // M3
input int InpM15MA=20;
input int InpHigherMA=20; // H1/H4
input int InpTrendMA=200; // D1, only if enabled
input ENUM_MA_METHOD InpMAMethod=MODE_EMA;
input ENUM_APPLIED_PRICE InpMAPrice=PRICE_CLOSE;
input int InpSlopeBars=3;
input double InpMinTrendSlopeATR=0.02;
input bool InpTrendRequirePriceSide=false; // default direction uses MA slope only
input bool InpUseADX=true; // supplemental condition, not a claimed personal rule
input int InpADXPeriod=14;
input double InpMinADX=20.0;
input int InpATRPeriod=14;
input double InpMinATR=0.0;
input double InpMaxATR=0.0;

input group "M3 MA touch + RSI + rejection wick"
input ENUM_HN_TOUCH InpTouchMode=MA_REBOUND;
input double InpTouchATR=0.2;
input bool InpUseRSI=true;
input int InpRSIPeriod=14;
input double InpRSIBuyLevel=20.0;
input double InpRSISellLevel=80.0;
input int InpRSILookback=1; // 1: same confirmed signal bar; >1 explicitly changes hypothesis
input bool InpUseWickFilter=true;
input double InpWickBodyRatio=1.5;
input double InpLowerWickPercent=40.0;
input double InpUpperWickPercent=40.0;
input double InpBodyFloorPoints=1.0; // denominator floor for doji
input bool InpRequireSignalColor=false;
input int InpCooldownBars=1;

input group "Stop / take profit"
input ENUM_HN_SL_BASIS InpSLBasis=SWING_STOP;
input int InpSwingLookback=10;
input double InpSLBufferATR=0.1;
input double InpSLATRMultiplier=1.0;
input double InpSLDistancePrice=2.0; // price units, not ambiguously named gold pips
input ENUM_HN_SL InpSLMode=FIXED_STOP; // new specification places SL at entry
input double InpEmergencySLMultiplier=3.0;
input ENUM_HN_TP InpTPMode=BB_TARGET;
input int InpBBPeriod=20;
input double InpBBDeviation=2.0;
input ENUM_TIMEFRAMES InpBBTimeframe=PERIOD_M3;
input double InpRiskReward=1.5;

input group "Optional simple H1/H4 opposite barrier"
input bool InpUseSupportResistance=false; // V1 simple closed-bar extremes; advanced zones deferred
input int InpSRLookback=50;
input double InpSRDistanceATR=0.5; // M3 ATR units

input group "Daily limits (0 disables; server day)"
input double InpMaxDailyLossPercent=0.0;
input bool InpCloseOnDailyLoss=true;
input int InpMaxDailyTrades=0;
input int InpMaxConsecutiveLosses=0;

struct Snapshot
  {
   int d1,h4,h1,m15;
   double slope,adx,atr,spread,logicalSL,tp,riskMoney;
   double rsi,rsiGate,ma,m15ma,m15Slope,wick,body,wickRatio,wickPercent,support,resistance;
  };
CTrade trade;
ENUM_TIMEFRAMES frames[5]={PERIOD_D1,PERIOD_H4,PERIOD_H1,PERIOD_M15,PERIOD_M3};
int trendMA[3],fastMA[2],atrHandle[5],adxHandle=INVALID_HANDLE;
int rsiHandle=INVALID_HANDLE,bbHandle=INVALID_HANDLE;
double stepBalances[],stepLots[];
MqlRates bars[];
double m3Fast[],m3ATR[],m3RSI[];
Snapshot snap;
Snapshot panel;
ulong statePositionId=0;
datetime lastBar=0,dayStart=0,lastHistoryRefresh=0,lastCloseAttempt=0,panelBar=0;
double dayStartBalance=0,realizedToday=0,lastLot=0,currentSpread=0;
int tradesToday=0,lossStreak=0,logHandle=INVALID_HANDLE;
bool dayHalted=false,historyDirty=true,historyOK=false,tester=false;
string g_hnStatusText="INITIALIZING",statePrefix="",pendingCloseReason="";
bool stateHealthy=true;
bool decisionPending=false,signalDataReady=false,ruinObserved=false;
int decisionHandle=INVALID_HANDLE,decisionDirection=0;
double stepConversion=1.0,requiredMargin=0,marginBudget=0;
datetime lastClosedBar=0;
string reasonNames[];
long reasonCounts[];
datetime observedDays[];
int observedEntries[];
ulong observedEntryOrders[],stopOutPositions[];
long evaluatedBars=0;

int ObserveDay(const datetime time)
  {
   datetime date=ServerDay(time); int n=ArraySize(observedDays);
   for(int i=n-1;i>=0;i--) if(observedDays[i]==date) return i;
   ArrayResize(observedDays,n+1); ArrayResize(observedEntries,n+1);
   observedDays[n]=date; observedEntries[n]=0; return n;
  }
void RecordDecision()
  {
   evaluatedBars++;
   int n=ArraySize(reasonNames),index=-1;
   for(int i=0;i<n;i++) if(reasonNames[i]==g_hnStatusText) { index=i; break; }
   if(index<0) { index=n; ArrayResize(reasonNames,n+1); ArrayResize(reasonCounts,n+1); reasonNames[n]=g_hnStatusText; reasonCounts[n]=0; }
   reasonCounts[index]++;
   if(decisionHandle!=INVALID_HANDLE)
      FileWrite(decisionHandle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),g_hnStatusText,signalDataReady,
                decisionDirection,AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY),
                lastLot,requiredMargin,marginBudget,currentSpread,signalDataReady ? snap.m15 : 0,
                signalDataReady ? snap.h1 : 0,signalDataReady ? snap.h4 : 0,
                signalDataReady ? snap.ma : 0.0,signalDataReady ? snap.rsi : 0.0,
                signalDataReady ? snap.rsiGate : 0.0,signalDataReady ? snap.wickRatio : 0.0,
                signalDataReady ? snap.wickPercent : 0.0,signalDataReady ? snap.adx : 0.0,
                signalDataReady ? snap.atr : 0.0,signalDataReady ? snap.m15ma : 0.0,
                signalDataReady ? snap.m15Slope : 0.0,signalDataReady ? snap.support : 0.0,
                signalDataReady ? snap.resistance : 0.0);
  }


string IdText(const ulong id) { return StringFormat("%I64u",id); }
datetime ServerDay(const datetime value)
  {
   MqlDateTime t; TimeToStruct(value,t); t.hour=0; t.min=0; t.sec=0;
   return StructToTime(t);
  }
string StateKey(const ulong id,const string suffix)
  { return statePrefix+IdText(id)+"."+suffix; }
bool ValidTag()
  {
   if(StringLen(InpRunTag)<1 || StringLen(InpRunTag)>32) return false;
   for(int i=0;i<StringLen(InpRunTag);i++)
     {
      ushort c=StringGetCharacter(InpRunTag,i);
      if(!((c>=48 && c<=57)||(c>=65 && c<=90)||(c>=97 && c<=122)||c==95||c==45)) return false;
     }
   return true;
  }
bool StrictNumber(string text,double &value)
  {
   StringTrimLeft(text); StringTrimRight(text);
   bool digit=false; int dots=0;
   for(int i=0;i<StringLen(text);i++)
     {
      ushort c=StringGetCharacter(text,i);
      if(c>=48 && c<=57) { digit=true; continue; }
      if(c==46 && dots==0) { dots++; continue; }
      if(i==0 && (c==43 || c==45)) continue;
      return false;
     }
   if(!digit) return false;
   value=StringToDouble(text); return MathIsValidNumber(value);
  }
bool ParseSteps()
  {
   string rows[];
   int n=StringSplit(InpBalanceLotSteps,StringGetCharacter(";",0),rows);
   if(n<1) return false;
   ArrayResize(stepBalances,n); ArrayResize(stepLots,n);
   for(int i=0;i<n;i++)
     {
      string pair[];
      if(StringSplit(rows[i],StringGetCharacter(":",0),pair)!=2) return false;
      if(!StrictNumber(pair[0],stepBalances[i]) || !StrictNumber(pair[1],stepLots[i])) return false;
      if(stepBalances[i]<0 || stepLots[i]<=0 || (i>0 && stepBalances[i]<=stepBalances[i-1])) return false;
     }
   return true;
  }
bool BufferValue(const int handle,const int buffer,const int shift,double &value)
  {
   double v[1];
   if(handle==INVALID_HANDLE || BarsCalculated(handle)<=shift || CopyBuffer(handle,buffer,shift,1,v)!=1) return false;
   value=v[0]; return MathIsValidNumber(value) && value!=EMPTY_VALUE;
  }
int TrendDirection(const int ma,const int atr,const ENUM_TIMEFRAMES tf)
  {
   double now,before,av;
   if(!BufferValue(ma,0,1,now)||!BufferValue(ma,0,1+InpSlopeBars,before)||!BufferValue(atr,0,1,av)||av<=0) return 0;
   double normalized=(now-before)/av;
   double close=iClose(_Symbol,tf,1);
   if(normalized>InpMinTrendSlopeATR && (!InpTrendRequirePriceSide || close>now)) return 1;
   if(normalized<-InpMinTrendSlopeATR && (!InpTrendRequirePriceSide || close<now)) return -1;
   return 0;
  }
bool ReadSignalData()
  {
   int need=(int)MathMax(InpSwingLookback+3,InpRSILookback+2);
   need=(int)MathMax(need,InpSlopeBars+3);
   ArraySetAsSeries(bars,true); ArraySetAsSeries(m3Fast,true); ArraySetAsSeries(m3ATR,true); ArraySetAsSeries(m3RSI,true);
   if(CopyRates(_Symbol,PERIOD_M3,0,need,bars)!=need || CopyBuffer(fastMA[1],0,0,need,m3Fast)!=need ||
      CopyBuffer(atrHandle[4],0,0,need,m3ATR)!=need || CopyBuffer(rsiHandle,0,0,need,m3RSI)!=need) return false;
   for(int i=1;i<need;i++)
      if(m3ATR[i]<=0 || m3ATR[i]==EMPTY_VALUE || !MathIsValidNumber(m3ATR[i]) ||
         m3Fast[i]==EMPTY_VALUE || !MathIsValidNumber(m3Fast[i]) ||
         m3RSI[i]==EMPTY_VALUE || !MathIsValidNumber(m3RSI[i])) return false;
   int periods[5]={InpTrendMA,InpHigherMA,InpHigherMA,InpM15MA,InpFastMA};
   bool enabled[5]={InpUseD1Trend,InpUseH4Trend,InpUseH1Trend,true,true};
   for(int i=0;i<5;i++) if(enabled[i] && BarsCalculated(atrHandle[i])<periods[i]+InpSlopeBars+2) return false;
   if(InpUseADX && !BufferValue(adxHandle,0,1,snap.adx)) return false;
   if(!InpUseADX) snap.adx=0;
   snap.atr=m3ATR[1]; snap.ma=m3Fast[1]; snap.rsi=m3RSI[1]; snap.rsiGate=snap.rsi;
   snap.slope=(m3Fast[1]-m3Fast[1+InpSlopeBars])/snap.atr;
   double previous,m15ATR;
   if(!BufferValue(fastMA[0],0,1,snap.m15ma)||!BufferValue(fastMA[0],0,1+InpSlopeBars,previous)||
      !BufferValue(atrHandle[3],0,1,m15ATR)||m15ATR<=0) return false;
   snap.m15Slope=(snap.m15ma-previous)/m15ATR;
   snap.d1=(InpUseD1Trend ? TrendDirection(trendMA[0],atrHandle[0],PERIOD_D1) : 0);
   snap.h4=(InpUseH4Trend ? TrendDirection(trendMA[1],atrHandle[1],PERIOD_H4) : 0);
   snap.h1=(InpUseH1Trend ? TrendDirection(trendMA[2],atrHandle[2],PERIOD_H1) : 0);
   snap.m15=TrendDirection(fastMA[0],atrHandle[3],PERIOD_M15);
   snap.support=0; snap.resistance=0; snap.wick=0; snap.body=0; snap.wickRatio=0; snap.wickPercent=0;
   return true;
  }
bool AlignmentPass(const int dir,const int actual)
  { return InpTrendAlignment==STRICT_ALIGNMENT ? actual==dir : actual!=-dir; }
int AllowedDirection()
  {
   int dir=snap.m15;
   if(dir==0) { g_hnStatusText="WAIT M15 TREND"; return 0; }
   if((InpTrendMode==LONG_ONLY && dir!=1)||(InpTrendMode==SHORT_ONLY && dir!=-1)||
      (dir==1 && !InpEnableLong)||(dir==-1 && !InpEnableShort)) { g_hnStatusText="DIRECTION DISABLED"; return 0; }
   if((InpUseD1Trend && !AlignmentPass(dir,snap.d1))||(InpUseH1Trend && !AlignmentPass(dir,snap.h1))||
      (InpUseH4Trend && !AlignmentPass(dir,snap.h4))) { g_hnStatusText="TREND MISMATCH"; return 0; }
   return dir;
  }
bool SupportResistancePass(const int dir,const double entry)
  {
   if(!InpUseSupportResistance) return true;
   ENUM_TIMEFRAMES srFrames[2]={PERIOD_H1,PERIOD_H4};
   double nearestSupport=0,nearestResistance=0;
   for(int f=0;f<2;f++)
     {
      MqlRates levels[];
      if(CopyRates(_Symbol,srFrames[f],1,InpSRLookback,levels)!=InpSRLookback) { g_hnStatusText="SR DATA NOT READY"; return false; }
      for(int i=0;i<InpSRLookback;i++)
        {
         double high=levels[i].high,low=levels[i].low;
         // Simple causal confirmed swing pivots, two already-closed neighbours per side.
         if(i<2 || i>=InpSRLookback-2) continue;
         bool pivotHigh=(high>levels[i-1].high && high>levels[i-2].high && high>levels[i+1].high && high>levels[i+2].high);
         bool pivotLow=(low<levels[i-1].low && low<levels[i-2].low && low<levels[i+1].low && low<levels[i+2].low);
         if(pivotHigh && high>entry && (nearestResistance==0 || high<nearestResistance)) nearestResistance=high;
         if(pivotLow && low<entry && low>nearestSupport) nearestSupport=low;
        }
     }
   snap.support=nearestSupport; snap.resistance=nearestResistance;
   double distance=(dir==1 ? nearestResistance-entry : entry-nearestSupport);
   bool exists=(dir==1 ? nearestResistance>0 : nearestSupport>0);
   if(exists && distance<=snap.atr*InpSRDistanceATR) { g_hnStatusText="SR BARRIER TOO CLOSE"; return false; }
   return true;
  }
bool Pullback(const int dir)
  {
   double ma=m3Fast[1],tolerance=m3ATR[1]*InpTouchATR;
   if(InpTouchMode==MA_REBOUND)
      return dir==1 ? bars[1].low<=ma && bars[1].close>=ma : bars[1].high>=ma && bars[1].close<=ma;
   if(InpTouchMode==CLOSE_NEAR_MA) return MathAbs(bars[1].close-ma)<=tolerance;
   double lowBody=MathMin(bars[1].open,bars[1].close),highBody=MathMax(bars[1].open,bars[1].close);
   return MathMax(0.0,MathMax(lowBody-ma,ma-highBody))<=tolerance;
  }
bool WickPass(const int dir)
  {
   snap.body=MathAbs(bars[1].close-bars[1].open);
   snap.wick=(dir==1 ? MathMin(bars[1].open,bars[1].close)-bars[1].low : bars[1].high-MathMax(bars[1].open,bars[1].close));
   double range=bars[1].high-bars[1].low;
   if(range<=0) return false;
   snap.wickRatio=snap.wick/MathMax(snap.body,InpBodyFloorPoints*_Point);
   snap.wickPercent=snap.wick/range*100.0;
   return !InpUseWickFilter || (snap.wickRatio>=InpWickBodyRatio && snap.wickPercent>=(dir==1 ? InpLowerWickPercent : InpUpperWickPercent));
  }
bool EntrySignal(const int dir,double &swing)
  {
   bool wickOK=WickPass(dir); // calculate metrics even when another gate fails
   for(int i=2;i<=InpRSILookback;i++)
      snap.rsiGate=(dir==1 ? MathMin(snap.rsiGate,m3RSI[i]) : MathMax(snap.rsiGate,m3RSI[i]));
   if(!Pullback(dir)) { g_hnStatusText="WAIT M3 PULLBACK"; return false; }
   if(InpUseRSI && ((dir==1 && snap.rsiGate>InpRSIBuyLevel)||(dir==-1 && snap.rsiGate<InpRSISellLevel)))
     { g_hnStatusText="WAIT RSI"; return false; }
   if(!wickOK || (InpRequireSignalColor && dir*(bars[1].close-bars[1].open)<=0))
     { g_hnStatusText="WAIT PRICE ACTION"; return false; }
   swing=(dir==1 ? bars[1].low : bars[1].high);
   if(InpSLBasis==SWING_STOP)
      for(int i=2;i<=InpSwingLookback;i++) swing=(dir==1 ? MathMin(swing,bars[i].low) : MathMax(swing,bars[i].high));
   return true;
  }
bool OwnSelectedPosition()
  {
   return PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic;
  }
int OwnPositions()
  {
   int count=0;
   for(int i=0;i<PositionsTotal();i++) if(PositionGetTicket(i)!=0 && OwnSelectedPosition()) count++;
   return count;
  }
bool AnySymbolExposure()
  {
   for(int i=0;i<PositionsTotal();i++) if(PositionGetTicket(i)!=0 && PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   for(int i=0;i<OrdersTotal();i++) if(OrderGetTicket(i)!=0 && OrderGetString(ORDER_SYMBOL)==_Symbol) return true;
   return false;
  }
bool PositionIsOpen(const ulong id)
  {
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)!=0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==id) return true;
   return false;
  }
double FloatingPL()
  {
   double sum=0;
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)!=0 && OwnSelectedPosition()) sum+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   return sum;
  }
double DealNet(const ulong id)
  { return HistoryDealGetDouble(id,DEAL_PROFIT)+HistoryDealGetDouble(id,DEAL_COMMISSION)+HistoryDealGetDouble(id,DEAL_SWAP)+HistoryDealGetDouble(id,DEAL_FEE); }
bool HasId(const ulong &ids[],const ulong id)
  { for(int i=0;i<ArraySize(ids);i++) if(ids[i]==id) return true; return false; }
void AppendId(ulong &ids[],const ulong id)
  { int n=ArraySize(ids); ArrayResize(ids,n+1); ids[n]=id; }
bool StrategyDeal(const ulong id,const ulong &owned[])
  {
   if(HistoryDealGetString(id,DEAL_SYMBOL)!=_Symbol || ArraySize(owned)==0) return false;
   ulong pid=(ulong)HistoryDealGetInteger(id,DEAL_POSITION_ID);
   int index=ArrayBsearch(owned,pid);
   return index>=0 && owned[index]==pid;
  }
bool RefreshHistory()
  {
   datetime now=TimeCurrent(),newDay=ServerDay(now);
   bool changed=(newDay!=dayStart);
   if(changed)
     {
      dayStart=newDay; dayHalted=false;
      if(OwnPositions()==0) pendingCloseReason="";
      if(!tester && GlobalVariableCheck(statePrefix+"haltDay")) dayHalted=((datetime)GlobalVariableGet(statePrefix+"haltDay")==dayStart);
     }
   if(!HistorySelect(0,now)) { historyOK=false; return false; }
   int n=HistoryDealsTotal(); ulong owned[],entryOrders[];
   // Collect strategy position ids from entry magic, including manually closed exits.
   for(int i=0;i<n;i++)
     {
      ulong id=HistoryDealGetTicket(i);
      if(HistoryDealGetString(id,DEAL_SYMBOL)==_Symbol && (ulong)HistoryDealGetInteger(id,DEAL_MAGIC)==InpMagic &&
         (ENUM_DEAL_ENTRY)HistoryDealGetInteger(id,DEAL_ENTRY)==DEAL_ENTRY_IN)
        { ulong pid=(ulong)HistoryDealGetInteger(id,DEAL_POSITION_ID); AppendId(owned,pid); }
     }
   ArraySort(owned);
   realizedToday=0; tradesToday=0; lossStreak=0; double accountChange=0;
   ulong completed[];
   for(int i=0;i<n;i++)
     {
      ulong id=HistoryDealGetTicket(i); datetime t=(datetime)HistoryDealGetInteger(id,DEAL_TIME);
      // Initial tester deposit is not a loss/profit during the first observed day.
      ENUM_DEAL_TYPE dealType=(ENUM_DEAL_TYPE)HistoryDealGetInteger(id,DEAL_TYPE);
      if(t>=dayStart && !(tester && (dealType==DEAL_TYPE_BALANCE || dealType==DEAL_TYPE_CREDIT))) accountChange+=DealNet(id);
      if(!StrategyDeal(id,owned)) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(id,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
        { int shift=iBarShift(_Symbol,PERIOD_M3,t,false); if(shift>=0) lastClosedBar=(datetime)MathMax((double)lastClosedBar,(double)iTime(_Symbol,PERIOD_M3,shift)); }
      if(t>=dayStart)
        {
         realizedToday+=DealNet(id);
         if(entry==DEAL_ENTRY_IN)
           { ulong oid=(ulong)HistoryDealGetInteger(id,DEAL_ORDER); if(!HasId(entryOrders,oid)) { AppendId(entryOrders,oid); tradesToday++; } }
        }
     }
   // Today's completed positions only. Total lifecycle P/L includes entry fees.
   for(int i=n-1;i>=0;i--)
     {
      ulong id=HistoryDealGetTicket(i); datetime t=(datetime)HistoryDealGetInteger(id,DEAL_TIME);
      if(t<dayStart) break;
      if(!StrategyDeal(id,owned)) continue;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(id,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
      ulong pid=(ulong)HistoryDealGetInteger(id,DEAL_POSITION_ID);
      if(HasId(completed,pid) || PositionIsOpen(pid)) continue;
      AppendId(completed,pid); double net=0;
      for(int j=0;j<n;j++)
        { ulong d=HistoryDealGetTicket(j); if(StrategyDeal(d,owned) && (ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)==pid) net+=DealNet(d); }
      if(net<0) lossStreak++; else break;
     }
   dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE)-accountChange;
   historyDirty=false; lastHistoryRefresh=now; historyOK=(dayStartBalance>0);
   return historyOK;
  }
void LatchDailyStop()
  {
   if(dayHalted) return;
   dayHalted=true;
   if(!tester) { GlobalVariableSet(statePrefix+"haltDay",(double)dayStart); GlobalVariablesFlush(); }
  }
void SavePositionState(const ulong id)
  {
   statePositionId=id;
   if(tester) return;
   // SL is the commit marker; store the rest first.
   GlobalVariableSet(StateKey(id,"D1"),snap.d1); GlobalVariableSet(StateKey(id,"H4"),snap.h4);
   GlobalVariableSet(StateKey(id,"H1"),snap.h1); GlobalVariableSet(StateKey(id,"M15"),snap.m15);
   GlobalVariableSet(StateKey(id,"slope"),snap.slope); GlobalVariableSet(StateKey(id,"adx"),snap.adx);
   GlobalVariableSet(StateKey(id,"atr"),snap.atr); GlobalVariableSet(StateKey(id,"spread"),snap.spread);
   GlobalVariableSet(StateKey(id,"tp"),snap.tp); GlobalVariableSet(StateKey(id,"risk"),snap.riskMoney);
   GlobalVariableSet(StateKey(id,"rsi"),snap.rsi);
   GlobalVariableSet(StateKey(id,"rsiGate"),snap.rsiGate);
   GlobalVariableSet(StateKey(id,"ma"),snap.ma);
   GlobalVariableSet(StateKey(id,"m15ma"),snap.m15ma);
   GlobalVariableSet(StateKey(id,"m15Slope"),snap.m15Slope);
   GlobalVariableSet(StateKey(id,"wick"),snap.wick);
   GlobalVariableSet(StateKey(id,"body"),snap.body);
   GlobalVariableSet(StateKey(id,"wickRatio"),snap.wickRatio);
   GlobalVariableSet(StateKey(id,"wickPercent"),snap.wickPercent);
   GlobalVariableSet(StateKey(id,"support"),snap.support);
   GlobalVariableSet(StateKey(id,"resistance"),snap.resistance);
   GlobalVariableSet(StateKey(id,"close"),0.0);
   stateHealthy=(GlobalVariableSet(StateKey(id,"SL"),snap.logicalSL)!=0);
   GlobalVariablesFlush();
  }
bool LoadPositionState(const ulong id)
  {
   if(id==statePositionId) return stateHealthy;
   if(tester || !GlobalVariableCheck(StateKey(id,"SL"))) return false;
   snap.logicalSL=GlobalVariableGet(StateKey(id,"SL")); snap.tp=GlobalVariableGet(StateKey(id,"tp"));
   snap.d1=(int)GlobalVariableGet(StateKey(id,"D1")); snap.h4=(int)GlobalVariableGet(StateKey(id,"H4"));
   snap.h1=(int)GlobalVariableGet(StateKey(id,"H1")); snap.m15=(int)GlobalVariableGet(StateKey(id,"M15"));
   snap.slope=GlobalVariableGet(StateKey(id,"slope")); snap.adx=GlobalVariableGet(StateKey(id,"adx"));
   snap.atr=GlobalVariableGet(StateKey(id,"atr")); snap.spread=GlobalVariableGet(StateKey(id,"spread"));
   snap.riskMoney=GlobalVariableGet(StateKey(id,"risk")); statePositionId=id;
   snap.rsi=GlobalVariableGet(StateKey(id,"rsi"));
   snap.rsiGate=GlobalVariableGet(StateKey(id,"rsiGate"));
   snap.ma=GlobalVariableGet(StateKey(id,"ma"));
   snap.m15ma=GlobalVariableGet(StateKey(id,"m15ma"));
   snap.m15Slope=GlobalVariableGet(StateKey(id,"m15Slope"));
   snap.wick=GlobalVariableGet(StateKey(id,"wick"));
   snap.body=GlobalVariableGet(StateKey(id,"body"));
   snap.wickRatio=GlobalVariableGet(StateKey(id,"wickRatio"));
   snap.wickPercent=GlobalVariableGet(StateKey(id,"wickPercent"));
   snap.support=GlobalVariableGet(StateKey(id,"support"));
   snap.resistance=GlobalVariableGet(StateKey(id,"resistance"));
   int pending=(int)GlobalVariableGet(StateKey(id,"close"));
   if(pending==1) pendingCloseReason="CLOSE_BAR_SL";
   if(pending==2) pendingCloseReason="DAILY_LOSS_LIMIT";
   if(pending==3) pendingCloseReason="MISSING_STOP_STATE";
   stateHealthy=(snap.logicalSL>0); return stateHealthy;
  }
bool TradeDone(const bool returned)
  {
   uint r=trade.ResultRetcode();
   return returned && (r==TRADE_RETCODE_DONE || r==TRADE_RETCODE_DONE_PARTIAL);
  }
void CloseOwned(const string reason)
  {
   if(TimeCurrent()==lastCloseAttempt) return;
   lastCloseAttempt=TimeCurrent();
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i); if(ticket==0 || !OwnSelectedPosition()) continue;
      if(pendingCloseReason!=reason) PrintFormat("HN_EXIT %s position=%I64u",reason,(ulong)PositionGetInteger(POSITION_IDENTIFIER));
      pendingCloseReason=reason;
      if(!tester)
        {
         ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
         int code=(reason=="CLOSE_BAR_SL" ? 1 : (reason=="DAILY_LOSS_LIMIT" ? 2 : 3));
         GlobalVariableSet(StateKey(pid,"close"),code); GlobalVariablesFlush();
        }
      if(!TradeDone(trade.PositionClose(ticket,(ulong)InpMaxSlippagePoints)))
         PrintFormat("CLOSE_FAILED %s: %u %s",reason,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      historyDirty=true;
     }
  }
void ManageStops()
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i); if(ticket==0 || !OwnSelectedPosition()) continue;
      ulong pid=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(pendingCloseReason!="") { CloseOwned(pendingCloseReason); return; }
      bool stored=LoadPositionState(pid);
      if(pendingCloseReason!="") { CloseOwned(pendingCloseReason); return; }
      if(InpSLMode!=CLOSE_BAR_STOP) continue;
      if(!stored) { g_hnStatusText="MISSING STOP STATE"; CloseOwned("MISSING_STOP_STATE"); return; }
      double close=iClose(_Symbol,PERIOD_M3,1); if(close<=0) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((type==POSITION_TYPE_BUY && close<=snap.logicalSL)||(type==POSITION_TYPE_SELL && close>=snap.logicalSL))
        { CloseOwned("CLOSE_BAR_SL"); return; } // retries on following ticks if failed/partial
     }
  }
double NormalizePrice(const double price,const int rounding)
  {
   double size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(size<=0) return 0;
   double units=price/size;
   double rounded=(rounding<0 ? MathFloor(units+1e-9) : MathCeil(units-1e-9));
   return NormalizeDouble(rounded*size,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
  }
double NormalizeLotDown(const double requested)
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),minimum=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maximum=MathMin(InpMaxLot,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX));
   if(step<=0 || requested<=0 || maximum<minimum) return 0;
   double lot=NormalizeDouble(MathFloor(MathMin(requested,maximum)/step+1e-9)*step,8);
   if(lot<minimum-1e-9) return 0; // never round UP to the broker's minimum
   return lot;
  }
double CalculateLot(const int dir,const double entry,const double hardSL)
  {
   double requested=InpFixedLot;
   if(InpRiskMode==VIDEO_BALANCE_STEP)
     {
      double balance=AccountInfoDouble(ACCOUNT_BALANCE)*stepConversion; int n=ArraySize(stepBalances);
      if(n<1 || (InpStopBelowFirstStep && balance<stepBalances[0])) { g_hnStatusText="BELOW FIRST LOT STEP"; return 0; }
      requested=stepLots[0];
      for(int i=1;i<n;i++) if(balance>=stepBalances[i]) requested=stepLots[i];
      if(InpProportionalAboveLastStep && balance>stepBalances[n-1]) requested=stepLots[n-1]*balance/stepBalances[n-1];
     }
   ENUM_ORDER_TYPE type=(dir==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double reference=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),profit=0;
   if(reference<=0 || !OrderCalcProfit(type,_Symbol,reference,entry,hardSL,profit) || profit>=0)
     { g_hnStatusText="RISK CALC FAILED"; return 0; }
   double unitLoss=MathAbs(profit)/reference+InpRoundTripCostPerLot;
   if(InpRiskMode==RISK_PERCENT)
     {
      double base=MathMin(AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY));
      requested=(base*InpRiskPercent/100.0)/unitLoss;
     }
   double lot=NormalizeLotDown(requested);
   if(lot<=0) { g_hnStatusText="LOT BELOW MINIMUM"; return 0; }
   snap.riskMoney=unitLoss*lot; return lot;
  }
bool StopsValid(const int dir,const MqlTick &tick,const double sl,const double tp)
  {
   double minDistance=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double market=(dir==1 ? tick.bid : tick.ask);
   return sl>0 && tp>0 && dir*(market-sl)>minDistance && dir*(tp-market)>minDistance;
  }
void TryEntry(const int dir,const double swing,const MqlTick &tick)
  {
   double entry=(dir==1 ? tick.ask : tick.bid);
   double stopPrice=swing-dir*snap.atr*InpSLBufferATR;
   if(InpSLBasis==ATR_STOP) stopPrice=entry-dir*snap.atr*InpSLATRMultiplier;
   if(InpSLBasis==FIXED_DISTANCE_STOP) stopPrice=entry-dir*InpSLDistancePrice;
   snap.logicalSL=NormalizePrice(stopPrice,-dir);
   double distance=dir*(entry-snap.logicalSL);
   if(distance<=0) { g_hnStatusText="INVALID SWING STOP"; return; }
   double hardSL=(InpSLMode==CLOSE_BAR_STOP ? NormalizePrice(entry-dir*distance*InpEmergencySLMultiplier,-dir) : snap.logicalSL);
   double target=entry+dir*distance*InpRiskReward;
   if(InpTPMode==BB_TARGET)
     {
      if(!BufferValue(bbHandle,dir==1 ? 1 : 2,1,target)) { g_hnStatusText="BB DATA NOT READY"; return; }
      if(dir*(target-entry)<=0) { g_hnStatusText="BB TARGET NOT AHEAD"; return; }
     }
   snap.tp=NormalizePrice(target,dir); // closed band frozen at entry; never move SL away
   if(!StopsValid(dir,tick,hardSL,snap.tp)) { g_hnStatusText="BROKER STOP DISTANCE"; return; }
   double lot=CalculateLot(dir,entry,hardSL); lastLot=lot; if(lot<=0) return;
   double margin=0; marginBudget=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*InpMarginUsePercent/100.0; ENUM_ORDER_TYPE type=(dir==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(type,_Symbol,lot,entry,margin)) { g_hnStatusText="MARGIN CALC FAILED"; return; }
   requiredMargin=margin;
   if(margin>marginBudget) { g_hnStatusText="INSUFFICIENT MARGIN"; return; } // video lot is NOT reduced silently
   MqlTradeRequest request={}; MqlTradeCheckResult checked={};
   request.action=TRADE_ACTION_DEAL; request.symbol=_Symbol; request.magic=InpMagic;
   request.volume=lot; request.type=type; request.price=entry; request.sl=hardSL; request.tp=snap.tp;
   request.deviation=(ulong)InpMaxSlippagePoints;
   long fill=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK)!=0) request.type_filling=ORDER_FILLING_FOK;
   else if((fill & SYMBOL_FILLING_IOC)!=0) request.type_filling=ORDER_FILLING_IOC;
   else request.type_filling=ORDER_FILLING_RETURN;
   if(!OrderCheck(request,checked)) { g_hnStatusText="ORDER CHECK FAILED"; PrintFormat("CHECK: %u %s",checked.retcode,checked.comment); return; }
   pendingCloseReason="";
   bool sent=(dir==1 ? trade.Buy(lot,_Symbol,entry,hardSL,snap.tp,"HN_V1") : trade.Sell(lot,_Symbol,entry,hardSL,snap.tp,"HN_V1"));
   if(!TradeDone(sent))
     { g_hnStatusText="ORDER REJECTED"; PrintFormat("ENTRY: %u %s",trade.ResultRetcode(),trade.ResultRetcodeDescription()); historyDirty=true; return; }
   historyDirty=true; g_hnStatusText=(dir==1 ? "BUY OPEN" : "SELL OPEN");
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)!=0 && OwnSelectedPosition())
        { SavePositionState((ulong)PositionGetInteger(POSITION_IDENTIFIER)); break; }
  }
string DealReasonText(const ENUM_DEAL_REASON reason,const ENUM_DEAL_ENTRY entry)
  {
   if(entry==DEAL_ENTRY_IN) return "ENTRY";
   if(reason==DEAL_REASON_SL) return (InpSLMode==CLOSE_BAR_STOP ? "EMERGENCY_SL" : "FIXED_SL");
   if(reason==DEAL_REASON_TP) return InpTPMode==BB_TARGET ? "BB_TP" : "RR_TP";
   if(reason==DEAL_REASON_SO) return "STOP_OUT";
   if(reason==DEAL_REASON_EXPERT && pendingCloseReason!="") return pendingCloseReason;
   return EnumToString(reason);
  }
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0 || !HistoryDealSelect(trans.deal)) return;
   historyDirty=true; // includes other-symbol P/L and cash flows in the day-start denominator
   ulong id=trans.deal,pid=(ulong)HistoryDealGetInteger(id,DEAL_POSITION_ID);
   if(HistoryDealGetString(id,DEAL_SYMBOL)!=_Symbol) return;
   bool own=((ulong)HistoryDealGetInteger(id,DEAL_MAGIC)==InpMagic || pid==statePositionId ||
             (!tester && GlobalVariableCheck(StateKey(pid,"SL"))));
   if(!own) return;
   historyDirty=true;
   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(id,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_IN)
     {
      ulong oid=(ulong)HistoryDealGetInteger(id,DEAL_ORDER);
      if(!HasId(observedEntryOrders,oid)) { AppendId(observedEntryOrders,oid); int day=ObserveDay((datetime)HistoryDealGetInteger(id,DEAL_TIME)); observedEntries[day]++; }
     }
   if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
     {
      lastClosedBar=iTime(_Symbol,PERIOD_M3,0);
      if((ENUM_DEAL_REASON)HistoryDealGetInteger(id,DEAL_REASON)==DEAL_REASON_SO && !HasId(stopOutPositions,pid))
        { AppendId(stopOutPositions,pid); ruinObserved=true; }
     }
   bool snapshotKnown=LoadPositionState(pid);
   if(logHandle==INVALID_HANDLE) return;
   ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(id,DEAL_TYPE);
   ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(id,DEAL_REASON);
   // DEAL_* side is actual deal direction: a SELL exit closes a BUY position.
   FileWrite(logHandle,TimeToString((datetime)HistoryDealGetInteger(id,DEAL_TIME),TIME_DATE|TIME_SECONDS),
             EnumToString(entry),IdText(pid),IdText(id),EnumToString(type),HistoryDealGetDouble(id,DEAL_VOLUME),
             HistoryDealGetDouble(id,DEAL_PRICE),snapshotKnown ? snap.logicalSL : 0.0,
             snapshotKnown ? snap.tp : 0.0,snapshotKnown ? snap.d1 : 0,snapshotKnown ? snap.h4 : 0,
             snapshotKnown ? snap.h1 : 0,snapshotKnown ? snap.m15 : 0,snapshotKnown ? snap.slope : 0.0,
             snapshotKnown ? snap.adx : 0.0,snapshotKnown ? snap.atr : 0.0,snapshotKnown ? snap.spread : 0.0,
             HistoryDealGetDouble(id,DEAL_PROFIT),HistoryDealGetDouble(id,DEAL_COMMISSION),
             HistoryDealGetDouble(id,DEAL_SWAP),HistoryDealGetDouble(id,DEAL_FEE),
             snapshotKnown ? snap.riskMoney : 0.0,DealReasonText(reason,entry),snapshotKnown,
             AccountInfoDouble(ACCOUNT_BALANCE),snapshotKnown ? snap.ma : 0.0,snapshotKnown ? snap.m15ma : 0.0,
             snapshotKnown ? snap.m15Slope : 0.0,snapshotKnown ? snap.rsi : 0.0,snapshotKnown ? snap.rsiGate : 0.0,
             snapshotKnown ? snap.wick : 0.0,snapshotKnown ? snap.body : 0.0,snapshotKnown ? snap.wickRatio : 0.0,
             snapshotKnown ? snap.wickPercent : 0.0,snapshotKnown ? snap.support : 0.0,snapshotKnown ? snap.resistance : 0.0);
   FileFlush(logHandle);
  }
void Display()
  {
   if(decisionPending) { RecordDecision(); decisionPending=false; }
   if(MQLInfoInteger(MQL_OPTIMIZATION) || (tester && !MQLInfoInteger(MQL_VISUAL_MODE))) return;
   datetime current=iTime(_Symbol,PERIOD_M3,0);
   if(current!=panelBar)
     {
      panelBar=current;
      panel.h4=(InpUseH4Trend ? TrendDirection(trendMA[1],atrHandle[1],PERIOD_H4) : 0);
      panel.h1=(InpUseH1Trend ? TrendDirection(trendMA[2],atrHandle[2],PERIOD_H1) : 0);
      panel.m15=TrendDirection(fastMA[0],atrHandle[3],PERIOD_M15);
      if(!BufferValue(rsiHandle,0,1,panel.rsi)) panel.rsi=0;
      if(!BufferValue(fastMA[1],0,1,panel.ma)) panel.ma=0;
      if(!BufferValue(adxHandle,0,1,panel.adx)) panel.adx=0;
      if(!BufferValue(atrHandle[4],0,1,panel.atr)) panel.atr=0;
     }
   Comment("Himeneko Gold Research V1.10 / RSI + WICK\n",_Symbol," / ",AccountInfoString(ACCOUNT_CURRENCY),
           "\nH4: ",panel.h4,"  H1: ",panel.h1,"  M15: ",panel.m15,
           "\nM3 MA: ",DoubleToString(panel.ma,_Digits),"  RSI: ",DoubleToString(panel.rsi,2),
           "\nLast evaluated wick/body: ",DoubleToString(snap.wickRatio,2)," wick%: ",DoubleToString(snap.wickPercent,1),
           "\nATR: ",DoubleToString(panel.atr,_Digits),"  ADX: ",DoubleToString(panel.adx,2),"  Spread: ",DoubleToString(currentSpread,1),
           "\nBalance: ",DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)," Last lot: ",DoubleToString(lastLot,4),
           "\nRequired margin: ",DoubleToString(requiredMargin,2)," Allowed: ",DoubleToString(marginBudget,2),
           "\nStep conversion (table units / account unit): ",DoubleToString(stepConversion,4),
           "\nDaily P/L incl. floating: ",DoubleToString(realizedToday+FloatingPL(),2),
           " Trades today: ",tradesToday," Loss streak(today): ",lossStreak,
           "\nEA STATUS: ",g_hnStatusText,
           "\nDecisions counted: ",evaluatedBars," (details: Journal / reasons.csv)");
  }
bool InputsValid()
  {
   return (int)InpRiskMode>=0 && (int)InpRiskMode<=2 && (int)InpSLMode>=0 && (int)InpSLMode<=1 &&
          (int)InpSLBasis>=0 && (int)InpSLBasis<=3 && (int)InpTPMode>=0 && (int)InpTPMode<=1 &&
          (int)InpTrendMode>=0 && (int)InpTrendMode<=2 && (int)InpTrendAlignment>=0 && (int)InpTrendAlignment<=1 &&
          (int)InpTouchMode>=0 && (int)InpTouchMode<=2 && (int)InpMAMethod>=0 && (int)InpMAMethod<=3 &&
          (int)InpMAPrice>=1 && (int)InpMAPrice<=7 && InpMagic>0 && InpMaxPositions==1 &&
          InpFastMA>=2 && InpFastMA<=2000 && InpM15MA>=2 && InpM15MA<=2000 &&
          InpHigherMA>=2 && InpHigherMA<=2000 && InpTrendMA>=2 && InpTrendMA<=2000 &&
          InpSlopeBars>=1 && InpSlopeBars<=50 && InpSwingLookback>=2 && InpSwingLookback<=200 &&
          InpATRPeriod>=2 && InpATRPeriod<=2000 && InpADXPeriod>=2 && InpADXPeriod<=2000 &&
          InpRSIPeriod>=2 && InpRSIPeriod<=2000 && InpRSILookback>=1 && InpRSILookback<=200 &&
          InpRSIBuyLevel>=0 && InpRSIBuyLevel<InpRSISellLevel && InpRSISellLevel<=100 &&
          InpWickBodyRatio>=0 && InpLowerWickPercent>=0 && InpLowerWickPercent<=100 &&
          InpUpperWickPercent>=0 && InpUpperWickPercent<=100 && InpBodyFloorPoints>0 && InpCooldownBars>=0 && InpCooldownBars<=2000 &&
          InpBBPeriod>=2 && InpBBPeriod<=2000 && InpBBDeviation>0 && PeriodSeconds(InpBBTimeframe)>0 &&
          InpSRLookback>=5 && InpSRLookback<=2000 && InpSRDistanceATR>=0 &&
          InpMinTrendSlopeATR>=0 && InpTouchATR>=0 && InpSLBufferATR>=0 && InpSLATRMultiplier>0 && InpSLDistancePrice>0 &&
          InpRiskReward>0 && InpEmergencySLMultiplier>=1 && InpRiskPercent>0 && InpRiskPercent<=100 &&
          InpFixedLot>0 && InpMaxLot>0 && InpRoundTripCostPerLot>=0 && InpMarginUsePercent>0 && InpMarginUsePercent<=100 &&
          InpStepUnitsPerAccountUnit>0 && InpMaxDailyLossPercent>=0 && InpMaxDailyLossPercent<=100 &&
          InpMaxDailyTrades>=0 && InpMaxConsecutiveLosses>=0 && InpMaxSpreadPoints>=0 && InpMaxSlippagePoints>=0 &&
          InpMinADX>=0 && InpMinADX<=100 && InpMinATR>=0 && InpMaxATR>=0 &&
          (InpMaxATR==0 || InpMaxATR>=InpMinATR) && ValidTag();
  }
int OnInit()
  {
   tester=(bool)MQLInfoInteger(MQL_TESTER);
   for(int i=0;i<3;i++) trendMA[i]=INVALID_HANDLE;
   for(int i=0;i<2;i++) fastMA[i]=INVALID_HANDLE;
   for(int i=0;i<5;i++) atrHandle[i]=INVALID_HANDLE;
   if(!InputsValid() || (InpRiskMode==VIDEO_BALANCE_STEP && !ParseSteps())) { Print("INVALID INPUT: check ranges, tag and balance:lot steps."); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskMode==VIDEO_BALANCE_STEP && AccountInfoString(ACCOUNT_CURRENCY)!=InpStepCurrency)
     {
      if(!InpUseManualStepConversion || AccountInfoString(ACCOUNT_CURRENCY)!=InpConversionAccountCurrency) { Print("STEP CURRENCY MISMATCH: enable explicit manual conversion or use matching currency/table."); return INIT_PARAMETERS_INCORRECT; }
      stepConversion=InpStepUnitsPerAccountUnit;
      PrintFormat("MANUAL STEP CONVERSION: 1 %s = %.6f %s (hypothetical fixed conversion, NOT current FX)",AccountInfoString(ACCOUNT_CURRENCY),stepConversion,InpStepCurrency);
     }
   if(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)<=0 || SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)<=0) return INIT_FAILED;
   // Tick event is tied to the attached/tested symbol; always use _Symbol.
   for(int i=0;i<5;i++) atrHandle[i]=iATR(_Symbol,frames[i],InpATRPeriod);
   if(InpUseD1Trend) trendMA[0]=iMA(_Symbol,PERIOD_D1,InpTrendMA,0,InpMAMethod,InpMAPrice);
   if(InpUseH4Trend) trendMA[1]=iMA(_Symbol,PERIOD_H4,InpHigherMA,0,InpMAMethod,InpMAPrice);
   if(InpUseH1Trend) trendMA[2]=iMA(_Symbol,PERIOD_H1,InpHigherMA,0,InpMAMethod,InpMAPrice);
   for(int i=0;i<2;i++)
     {
      fastMA[i]=iMA(_Symbol,frames[i+3],i==0 ? InpM15MA : InpFastMA,0,InpMAMethod,InpMAPrice);
     }
   adxHandle=iADX(_Symbol,PERIOD_H1,InpADXPeriod);
   rsiHandle=iRSI(_Symbol,PERIOD_M3,InpRSIPeriod,PRICE_CLOSE);
   bbHandle=iBands(_Symbol,InpBBTimeframe,InpBBPeriod,0,InpBBDeviation,PRICE_CLOSE);
   for(int i=0;i<5;i++) if(atrHandle[i]==INVALID_HANDLE) return INIT_FAILED;
   if((InpUseD1Trend && trendMA[0]==INVALID_HANDLE)||(InpUseH4Trend && trendMA[1]==INVALID_HANDLE)||
      (InpUseH1Trend && trendMA[2]==INVALID_HANDLE)) return INIT_FAILED;
   for(int i=0;i<2;i++) if(fastMA[i]==INVALID_HANDLE) return INIT_FAILED;
   if(adxHandle==INVALID_HANDLE || rsiHandle==INVALID_HANDLE || bbHandle==INVALID_HANDLE) return INIT_FAILED;
   statePrefix="HN110."+StringFormat("%I64d",AccountInfoInteger(ACCOUNT_LOGIN))+"."+IdText(InpMagic)+".";
   if(StringLen(statePrefix)>35) { Print("Magic/login too long for persistent keys"); return INIT_PARAMETERS_INCORRECT; }
   trade.SetExpertMagicNumber(InpMagic); trade.SetDeviationInPoints((ulong)InpMaxSlippagePoints);
   trade.SetAsyncMode(false); trade.SetTypeFillingBySymbol(_Symbol);
   RefreshHistory();
   // Skip the pre-attachment signal; first entry check is next M3 bar.
   lastBar=iTime(_Symbol,PERIOD_M3,0);
   if(InpWriteCSV && !MQLInfoInteger(MQL_OPTIMIZATION))
     {
      string name="HN_V110_"+InpRunTag+"_"+_Symbol+"_"+IdText(InpMagic)+"_deals.csv";
      int flags=FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI;
      if(tester) flags=FILE_WRITE|FILE_CSV|FILE_ANSI; // overwrite single test, no FILE_COMMON races
      logHandle=FileOpen(name,flags,',',CP_UTF8);
      if(logHandle==INVALID_HANDLE) { Print("CSV open failed: ",GetLastError()); return INIT_FAILED; }
      if(FileSize(logHandle)==0)
         FileWrite(logHandle,"time","entry","position_id","deal_id","deal_side","volume","price","logical_sl","tp",
                   "d1","h4","h1","m15","m3_slope_atr","adx","atr","entry_spread_points","profit","commission","swap","fee","initial_hard_risk_money","exit_reason","snapshot_known","balance_after_deal","m3_ma","m15_ma","m15_slope_atr",
                   "signal_rsi","gate_rsi","wick_length","body_length","wick_ratio","wick_percent","nearest_support","nearest_resistance");
      FileSeek(logHandle,0,SEEK_END);
     }
   if(InpWriteDecisionCSV && !MQLInfoInteger(MQL_OPTIMIZATION))
     {
      int flags=FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI;
      if(tester) flags=FILE_WRITE|FILE_CSV|FILE_ANSI;
      decisionHandle=FileOpen("HN_V110_"+InpRunTag+"_"+_Symbol+"_"+IdText(InpMagic)+"_decisions.csv",flags,',',CP_UTF8);
      if(decisionHandle==INVALID_HANDLE) return INIT_FAILED;
      if(FileSize(decisionHandle)==0)
         FileWrite(decisionHandle,"time","reason","signal_data_ready","direction","balance","equity","calculated_lot",
                   "required_margin","allowed_margin","spread_points","m15","h1","h4","m3_ma","signal_rsi","gate_rsi",
                   "wick_ratio","wick_percent","adx","atr","m15_ma","m15_slope_atr","support","resistance");
      FileSeek(decisionHandle,0,SEEK_END);
     }
   PrintFormat("HN V1.10 START: currency=%s leverage=1:%I64d balance=%.2f margin_budget_pct=%.1f daily_loss_pct=%.1f",
               AccountInfoString(ACCOUNT_CURRENCY),AccountInfoInteger(ACCOUNT_LEVERAGE),AccountInfoDouble(ACCOUNT_BALANCE),InpMarginUsePercent,InpMaxDailyLossPercent);
   g_hnStatusText="WAIT NEXT M3 BAR"; return INIT_SUCCEEDED;
  }
void OnTick()
  {
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0 || tick.ask<tick.bid) return;
   currentSpread=(tick.ask-tick.bid)/_Point;
   ObserveDay(TimeCurrent());
   if(AccountInfoDouble(ACCOUNT_EQUITY)<=0 || AccountInfoDouble(ACCOUNT_BALANCE)<=0) ruinObserved=true;
   if(historyDirty || !historyOK || ServerDay(TimeCurrent())!=dayStart) RefreshHistory();
   ManageStops(); // exit management never depends on entry spread/ADX/data filters
   if(historyOK && InpMaxDailyLossPercent>0 && realizedToday+FloatingPL()<=-dayStartBalance*InpMaxDailyLossPercent/100.0)
     { LatchDailyStop(); g_hnStatusText="DAILY LOSS LIMIT"; }
   if(dayHalted && InpCloseOnDailyLoss) CloseOwned("DAILY_LOSS_LIMIT");
   datetime current=iTime(_Symbol,PERIOD_M3,0);
   if(current<=0 || current==lastBar) { Display(); return; }
   lastBar=current; // at most one attempt per new bar, including rejected orders
   decisionPending=true; signalDataReady=false; decisionDirection=0; lastLot=0; requiredMargin=0;
   marginBudget=AccountInfoDouble(ACCOUNT_MARGIN_FREE)*InpMarginUsePercent/100.0;
   if(!historyOK) { g_hnStatusText="HISTORY NOT READY"; Display(); return; }
   if(dayHalted) { g_hnStatusText="DAILY HALT"; Display(); return; }
   if(!tester && !InpAllowLiveTrading) { g_hnStatusText="LIVE/DEMO ENTRY DISABLED"; Display(); return; }
   if(!tester && (!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)))
     { g_hnStatusText="TRADING PERMISSION DISABLED"; Display(); return; }
   if(OwnPositions()>=InpMaxPositions || AnySymbolExposure()) { g_hnStatusText="POSITION OPEN"; Display(); return; }
   if(lastClosedBar>0 && (iTime(_Symbol,PERIOD_M3,1)<=lastClosedBar || current-lastClosedBar<InpCooldownBars*PeriodSeconds(PERIOD_M3)))
     { g_hnStatusText="COOLDOWN"; Display(); return; }
   if(InpMaxDailyTrades>0 && tradesToday>=InpMaxDailyTrades) { g_hnStatusText="DAILY TRADE COUNT LIMIT"; Display(); return; }
   if(InpMaxConsecutiveLosses>0 && lossStreak>=InpMaxConsecutiveLosses) { LatchDailyStop(); g_hnStatusText="LOSS STREAK LIMIT"; Display(); return; }
   if(InpMaxSpreadPoints>0 && currentSpread>InpMaxSpreadPoints) { g_hnStatusText="SPREAD FILTER"; Display(); return; }
   if(!ReadSignalData()) { g_hnStatusText="INDICATORS WARMING UP"; Display(); return; }
   snap.spread=currentSpread; signalDataReady=true;
   if(InpUseADX && snap.adx<InpMinADX) { g_hnStatusText="ADX RANGE FILTER"; Display(); return; }
   if((InpMinATR>0 && snap.atr<InpMinATR)||(InpMaxATR>0 && snap.atr>InpMaxATR)) { g_hnStatusText="ATR FILTER"; Display(); return; }
   int dir=AllowedDirection(); decisionDirection=dir;
   if(dir==0) { Display(); return; }
   if(!SupportResistancePass(dir,dir==1 ? tick.ask : tick.bid)) { Display(); return; }
   double swing=0; if(EntrySignal(dir,swing)) TryEntry(dir,swing,tick);
   Display();
  }
double OnTester()
  {
   if(InpWriteCSV && !MQLInfoInteger(MQL_OPTIMIZATION))
     {
      int f=FileOpen("HN_V110_"+InpRunTag+"_summary.csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',',CP_UTF8);
      if(f!=INVALID_HANDLE)
        {
         FileWrite(f,"run_tag","risk_mode","risk_percent","initial_deposit","net_profit","balance_dd_pct","equity_dd_pct","profit_factor","win_rate_pct","average_win","average_loss","max_consecutive_losses","recovery_factor","trades","currency","max_consecutive_wins","observed_tick_days","average_entries_per_observed_day",
                   "average_entries_per_calendar_month","zero_entry_day_pct","max_entries_per_day","stop_out_positions","ruin_observed",
                   "final_balance","evaluated_m3_bars","step_conversion","tester_leverage","ea_version");
         int days=ArraySize(observedDays),zeroDays=0,maxDaily=0,entries=0;
         for(int i=0;i<days;i++) { entries+=observedEntries[i]; if(observedEntries[i]==0) zeroDays++; maxDaily=(int)MathMax(maxDaily,observedEntries[i]); }
         int months=0;
         if(days>0) { MqlDateTime first,last; TimeToStruct(observedDays[0],first); TimeToStruct(observedDays[days-1],last); months=(last.year-first.year)*12+last.mon-first.mon+1; }
         double total=TesterStatistics(STAT_TRADES),wins=TesterStatistics(STAT_PROFIT_TRADES),losses=TesterStatistics(STAT_LOSS_TRADES);
         FileWrite(f,InpRunTag,(int)InpRiskMode,InpRiskPercent,TesterStatistics(STAT_INITIAL_DEPOSIT),TesterStatistics(STAT_PROFIT),
                   TesterStatistics(STAT_BALANCE_DDREL_PERCENT),TesterStatistics(STAT_EQUITY_DDREL_PERCENT),TesterStatistics(STAT_PROFIT_FACTOR),
                   total>0 ? wins/total*100.0 : 0.0,wins>0 ? TesterStatistics(STAT_GROSS_PROFIT)/wins : 0.0,
                   losses>0 ? TesterStatistics(STAT_GROSS_LOSS)/losses : 0.0,TesterStatistics(STAT_MAX_CONLOSS_TRADES),
                   TesterStatistics(STAT_RECOVERY_FACTOR),total,AccountInfoString(ACCOUNT_CURRENCY),TesterStatistics(STAT_MAX_CONPROFIT_TRADES),
                   days,days>0 ? (double)entries/days : 0.0,months>0 ? (double)entries/months : 0.0,
                   days>0 ? (double)zeroDays/days*100.0 : 0.0,maxDaily,ArraySize(stopOutPositions),ruinObserved,
                   AccountInfoDouble(ACCOUNT_BALANCE),evaluatedBars,stepConversion,AccountInfoInteger(ACCOUNT_LEVERAGE),"1.10");
         FileClose(f);
        }
     }
   PrintFormat("HN V1.10 DECISION SUMMARY: evaluated=%I64d",evaluatedBars);
   int reasonFile=INVALID_HANDLE;
   if(InpWriteCSV && !MQLInfoInteger(MQL_OPTIMIZATION))
     { reasonFile=FileOpen("HN_V110_"+InpRunTag+"_reasons.csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',',CP_UTF8); if(reasonFile!=INVALID_HANDLE) FileWrite(reasonFile,"reason","bars"); }
   for(int i=0;i<ArraySize(reasonNames);i++)
     { PrintFormat("HN_REASON %s = %I64d",reasonNames[i],reasonCounts[i]); if(reasonFile!=INVALID_HANDLE) FileWrite(reasonFile,reasonNames[i],reasonCounts[i]); }
   if(reasonFile!=INVALID_HANDLE) FileClose(reasonFile);
   return TesterStatistics(STAT_RECOVERY_FACTOR);
  }
void OnDeinit(const int reason)
  {
   for(int i=0;i<5;i++) if(atrHandle[i]!=INVALID_HANDLE) IndicatorRelease(atrHandle[i]);
   for(int i=0;i<3;i++) if(trendMA[i]!=INVALID_HANDLE) IndicatorRelease(trendMA[i]);
   for(int i=0;i<2;i++) if(fastMA[i]!=INVALID_HANDLE) IndicatorRelease(fastMA[i]);
   if(adxHandle!=INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(rsiHandle!=INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(bbHandle!=INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(logHandle!=INVALID_HANDLE) FileClose(logHandle);
   if(decisionHandle!=INVALID_HANDLE) FileClose(decisionHandle);
   Comment("");
  }
