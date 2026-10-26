using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public sealed class CodexQuotaSnapshot {
    public string Status="Waiting", Primary="", Secondary="", Plan="";
    public DateTime UpdatedUtc;
    public bool Success;
}
public sealed class CodexQuotaReader : IDisposable {
    Task<CodexQuotaSnapshot> pending;
    DateTime nextAttempt=DateTime.MinValue;
    CodexQuotaSnapshot current=new CodexQuotaSnapshot();
    readonly string executable;
    readonly object gate=new object();Process runningChild;bool disposed;
    public CodexQuotaReader(string path){executable=path;}
    public CodexQuotaSnapshot Poll(){
        if(pending!=null&&pending.IsCompleted){
            var result=pending.Result;pending=null;
            current=result;
        }
        if(pending==null&&DateTime.UtcNow>=nextAttempt){
            nextAttempt=DateTime.UtcNow.AddMinutes(1);
            if(String.IsNullOrEmpty(executable))current=new CodexQuotaSnapshot{Status="Codex not found"};
            else if(!disposed)pending=Task.Run(()=>QueryCore(executable,RegisterChild));
        }
        if(current.Success&&DateTime.UtcNow-current.UpdatedUtc>TimeSpan.FromMinutes(2))current=new CodexQuotaSnapshot{Status="Quota unavailable"};
        return current;
    }
    public static bool CanDisplay(bool enabled,CodexQuotaSnapshot data){return enabled&&data!=null&&data.Success&&data.Status=="Live"&&DateTime.UtcNow-data.UpdatedUtc<=TimeSpan.FromMinutes(2);}
    static Dictionary<string,object> Object(object value){return value as Dictionary<string,object>;}
    static object Get(Dictionary<string,object> d,string key){object value;return d!=null&&d.TryGetValue(key,out value)?value:null;}
    static string Window(object value){
        var window=Object(value);if(window==null||Get(window,"usedPercent")==null||Get(window,"windowDurationMins")==null)return "";
        double used=Convert.ToDouble(window["usedPercent"]),minutes=Convert.ToDouble(window["windowDurationMins"]);
        if(Double.IsNaN(used)||Double.IsInfinity(used)||used<0||minutes<=0)return "";
        double left=Math.Max(0,100-used);
        string unit=minutes%1440==0?(minutes/1440).ToString("0")+"d":minutes%60==0?(minutes/60).ToString("0")+"h":minutes.ToString("0")+"m";
        return unit+" left "+left.ToString("0")+"%";
    }
    public static CodexQuotaSnapshot Parse(string json){
        var message=Object(new JavaScriptSerializer().DeserializeObject(json));
        var result=Object(Get(message,"result"));
        var byId=Object(Get(result,"rateLimitsByLimitId"));
        var quota=Object(Get(byId,"codex"));
        if(quota==null){quota=Object(Get(result,"rateLimits"));string id=Convert.ToString(Get(quota,"limitId"));if(id!=""&&id!="codex")quota=null;}
        string primary=Window(Get(quota,"primary")),secondary=Window(Get(quota,"secondary"));
        return new CodexQuotaSnapshot{Success=primary!=""||secondary!="",Status=primary!=""||secondary!=""?"Live":"Quota unavailable",Primary=primary,Secondary=secondary,Plan=Convert.ToString(Get(quota,"planType")),UpdatedUtc=DateTime.UtcNow};
    }
    void RegisterChild(Process child){lock(gate){runningChild=child;if(disposed)try{child.Kill();}catch{}}}
    public void Dispose(){lock(gate){disposed=true;if(runningChild!=null)try{if(!runningChild.HasExited){runningChild.Kill();runningChild.WaitForExit(1000);}}catch{}}}
    public static CodexQuotaSnapshot Query(string path){return QueryCore(path,null);}
    static CodexQuotaSnapshot QueryCore(string path,Action<Process> onStarted){
        Process child=null;
        try{
            var start=new ProcessStartInfo(path,"app-server --listen stdio://"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
            child=Process.Start(start);
            if(onStarted!=null)onStarted(child);
            var errorDrain=child.StandardError.ReadToEndAsync();
            child.StandardInput.WriteLine("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"hub_pc_monitor\",\"title\":\"Hub PC Monitor\",\"version\":\"0.4.0\"}}}");
            child.StandardInput.Flush();
            var clock=Stopwatch.StartNew();bool initialized=false;
            while(clock.ElapsedMilliseconds<15000){
                var line=child.StandardOutput.ReadLineAsync();
                if(!line.Wait(Math.Max(1,15000-(int)clock.ElapsedMilliseconds)))break;
                if(line.Result==null)break;
                Dictionary<string,object> message;
                try{message=Object(new JavaScriptSerializer().DeserializeObject(line.Result));}catch{continue;}
                var id=Get(message,"id");if(id==null)continue;
                if(Convert.ToString(id)=="1"){
                    if(Get(message,"error")!=null)return new CodexQuotaSnapshot{Status="Codex initialization failed"};
                    initialized=true;
                    child.StandardInput.WriteLine("{\"method\":\"initialized\"}");
                    child.StandardInput.WriteLine("{\"id\":2,\"method\":\"account/rateLimits/read\"}");child.StandardInput.Flush();
                }else if(initialized&&Convert.ToString(id)=="2")return Parse(line.Result);
            }
            return new CodexQuotaSnapshot{Status="Quota query timed out"};
        }catch{return new CodexQuotaSnapshot{Status="Quota unavailable"};}
        finally{if(child!=null){try{child.StandardInput.Close();if(!child.WaitForExit(500)){child.Kill();child.WaitForExit(1000);}}catch{}child.Dispose();}}
    }
}
