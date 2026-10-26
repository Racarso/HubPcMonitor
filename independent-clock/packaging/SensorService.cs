using System;
using System.IO;
using System.ServiceProcess;
using System.Threading;
using System.Web.Script.Serialization;

sealed class SensorService:ServiceBase {
    TemperatureSampler reader;Timer timer;int publishing;
    readonly string output=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"HubPcMonitorSensors","temperatures.json");
    SensorService(){ServiceName="HubPcMonitorSensors";CanStop=true;}
    protected override void OnStart(string[] args){
        reader=new TemperatureSampler(AppDomain.CurrentDomain.BaseDirectory,false);
        timer=new Timer(Publish,null,0,2000);
    }
    void Publish(object ignored){
        if(Interlocked.Exchange(ref publishing,1)!=0)return;
        try{
            var sample=reader.Poll();
            if(sample.UpdatedUtc==DateTime.MinValue)return;
            string temp=output+".tmp";
            File.WriteAllText(temp,new JavaScriptSerializer().Serialize(sample));
            if(File.Exists(output))File.Replace(temp,output,null);else File.Move(temp,output);
        }catch{}finally{Interlocked.Exchange(ref publishing,0);}
    }
    protected override void OnStop(){
        if(timer!=null){using(var done=new ManualResetEvent(false)){timer.Dispose(done);done.WaitOne(3000);}}
        if(reader!=null)reader.Dispose();
        try{File.Delete(output);}catch{}
    }
    static void Main(){Run(new SensorService());}
}
