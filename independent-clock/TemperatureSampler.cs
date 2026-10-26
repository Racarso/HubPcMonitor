using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public sealed class TemperatureSnapshot {
    public double? Cpu, Gpu;
    public string CpuSensor, GpuSensor, Error;
    public DateTime UpdatedUtc;
}
public sealed class TemperatureSampler : IDisposable {
    readonly string folder;
    readonly bool readService;
    readonly CancellationTokenSource stop=new CancellationTokenSource();
    readonly object gate=new object();
    Task worker;
    TemperatureSnapshot latest=new TemperatureSnapshot();
    public TemperatureSampler(string directory):this(directory,true){}
    public TemperatureSampler(string directory,bool serviceInput){folder=directory;readService=serviceInput;}
    static object Get(object o,string name){return o.GetType().GetProperty(name).GetValue(o,null);}
    static void Call(object o,string name){o.GetType().GetMethod(name,Type.EmptyTypes).Invoke(o,null);}
    public static int Rank(string type,string name){
        name=(name??"").ToLowerInvariant();
        if(type=="Cpu"){
            if(name.Contains("distance")||name.Contains("tjmax"))return -1;
            if(name.Contains("package")||name=="core (tctl/tdie)"||name=="core (tdie)")return 0;
            if(name=="core max")return 1;
            if(name.StartsWith("cpu core #"))return 2;
        }
        if(type.StartsWith("Gpu")&&(name=="gpu core"||name=="gpu temperature"))return 0;
        return -1;
    }
    static void ReadHardware(object hardware,TemperatureSnapshot data,ref int cpuRank,ref int gpuRank){
        Call(hardware,"Update");string type=Get(hardware,"HardwareType").ToString();
        foreach(object sensor in (IEnumerable)Get(hardware,"Sensors")){
            if(Get(sensor,"SensorType").ToString()!="Temperature")continue;
            object raw=Get(sensor,"Value");if(raw==null)continue;
            double value=Convert.ToDouble(raw);if(Double.IsNaN(value)||Double.IsInfinity(value)||value<0||value>125)continue;
            string name=Get(sensor,"Name").ToString();int rank=Rank(type,name);if(rank<0)continue;
            if(type=="Cpu"&&(rank<cpuRank||(rank==cpuRank&&(!data.Cpu.HasValue||value>data.Cpu.Value)))){data.Cpu=value;data.CpuSensor=name;cpuRank=rank;}
            if(type.StartsWith("Gpu")&&(rank<gpuRank||(rank==gpuRank&&(!data.Gpu.HasValue||value>data.Gpu.Value)))){data.Gpu=value;data.GpuSensor=Get(hardware,"Name")+" / "+name;gpuRank=rank;}
        }
        foreach(object sub in (IEnumerable)Get(hardware,"SubHardware"))ReadHardware(sub,data,ref cpuRank,ref gpuRank);
    }
    public TemperatureSnapshot Poll(){
        lock(gate){
            if(worker==null&&!stop.IsCancellationRequested)worker=Task.Run((Action)Run);
            if((DateTime.UtcNow-latest.UpdatedUtc).TotalSeconds>6)return new TemperatureSnapshot{Error=latest.Error};
            return latest;
        }
    }
    void Run(){
        object computer=null;
        ResolveEventHandler resolve=(sender,e)=>{
            string path=Path.Combine(folder,new AssemblyName(e.Name).Name+".dll");
            return File.Exists(path)?Assembly.LoadFrom(path):null;
        };
        AppDomain.CurrentDomain.AssemblyResolve+=resolve;
        try{
            Assembly assembly=Assembly.LoadFrom(Path.Combine(folder,"LibreHardwareMonitorLib.dll"));
            computer=Activator.CreateInstance(assembly.GetType("LibreHardwareMonitor.Hardware.Computer",true));
            computer.GetType().GetProperty("IsCpuEnabled").SetValue(computer,true,null);
            computer.GetType().GetProperty("IsGpuEnabled").SetValue(computer,true,null);
            Call(computer,"Open");
            while(!stop.IsCancellationRequested){
                var next=new TemperatureSnapshot();int cpuRank=Int32.MaxValue,gpuRank=Int32.MaxValue;
                try{
                    bool supplied=false;
                    if(readService){
                        try{
                            string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"HubPcMonitorSensors","temperatures.json");
                            var shared=new JavaScriptSerializer().Deserialize<TemperatureSnapshot>(File.ReadAllText(path));
                            if(shared!=null&&(DateTime.UtcNow-shared.UpdatedUtc).TotalSeconds>=0&&(DateTime.UtcNow-shared.UpdatedUtc).TotalSeconds<6){next=shared;supplied=true;}
                        }catch{}
                    }
                    if(!supplied)foreach(object hardware in (IEnumerable)Get(computer,"Hardware"))ReadHardware(hardware,next,ref cpuRank,ref gpuRank);
                }
                catch(Exception e){next.Cpu=null;next.Gpu=null;next.Error=e.GetBaseException().Message;}
                next.UpdatedUtc=DateTime.UtcNow;lock(gate){latest=next;}
                if(stop.Token.WaitHandle.WaitOne(2000))break;
            }
        }catch(Exception e){lock(gate){latest=new TemperatureSnapshot{Error=e.GetBaseException().Message};}}
        finally{if(computer!=null)try{Call(computer,"Close");}catch{}AppDomain.CurrentDomain.AssemblyResolve-=resolve;}
    }
    public void Dispose(){stop.Cancel();if(worker!=null)worker.Wait(1000);}
}
