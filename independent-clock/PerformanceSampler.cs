using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Threading;

public sealed class PcSnapshot {
    public double? CpuPercent, MemoryPercent;
    public double UsedMemoryGiB, TotalMemoryGiB;
}

public sealed class PcLoadSnapshot {
    public double? CpuGhz, CpuFrequencyPercent, GpuPercent;
    public DateTime UpdatedUtc;
}
// PDH collection stays off the USB/UI thread. No elevated service is needed.
public sealed class PcLoadReader:IDisposable {
    public static double? FrequencyRangePercent(double? current,double? baseline,double? turbo){
        if(!current.HasValue||!baseline.HasValue||!turbo.HasValue)return null;
        double c=current.Value,b=baseline.Value,t=turbo.Value;
        if(Double.IsNaN(c)||Double.IsInfinity(c)||Double.IsNaN(b)||Double.IsInfinity(b)||Double.IsNaN(t)||Double.IsInfinity(t)||c<0||b<=0||t<=b)return null;
        return Math.Max(0,Math.Min(100,(c-b)*100/(t-b)));
    }
    readonly object gate=new object();readonly ManualResetEvent stop=new ManualResetEvent(false);
    Thread worker;PcLoadSnapshot latest=new PcLoadSnapshot();
    [StructLayout(LayoutKind.Explicit,Size=16)]struct Value{[FieldOffset(0)]public uint Status;[FieldOffset(8)]public double Number;}
    [StructLayout(LayoutKind.Sequential)]struct Item{public IntPtr Name;public Value Value;}
    [DllImport("pdh.dll",CharSet=CharSet.Unicode)]static extern uint PdhOpenQueryW(string source,IntPtr user,out IntPtr query);
    [DllImport("pdh.dll",CharSet=CharSet.Unicode)]static extern uint PdhAddEnglishCounterW(IntPtr query,string path,IntPtr user,out IntPtr counter);
    [DllImport("pdh.dll")]static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")]static extern uint PdhGetFormattedCounterValue(IntPtr counter,uint format,IntPtr type,out Value value);
    [DllImport("pdh.dll",CharSet=CharSet.Unicode)]static extern uint PdhGetFormattedCounterArrayW(IntPtr counter,uint format,ref uint bytes,out uint count,IntPtr items);
    [DllImport("pdh.dll")]static extern uint PdhCloseQuery(IntPtr query);
    static double? Number(IntPtr counter){Value value;if(counter==IntPtr.Zero||PdhGetFormattedCounterValue(counter,0x8200,IntPtr.Zero,out value)!=0||value.Status>1||Double.IsNaN(value.Number)||Double.IsInfinity(value.Number)||value.Number<0)return null;return value.Number;}
    public static double? BusiestEngine(string[] names,double[] values){
        if(names==null||values==null||names.Length!=values.Length)throw new ArgumentException("GPU samples mismatch");
        var totals=new Dictionary<string,double>(StringComparer.OrdinalIgnoreCase);
        for(int i=0;i<names.Length;i++){
            if(names[i]==null||Double.IsNaN(values[i])||Double.IsInfinity(values[i])||values[i]<0)continue;
            int start=names[i].IndexOf("luid_",StringComparison.OrdinalIgnoreCase);if(start<0)continue;
            string key=names[i].Substring(start);int duplicate=key.IndexOf('#');if(duplicate>=0)key=key.Substring(0,duplicate);
            double sum;totals.TryGetValue(key,out sum);totals[key]=sum+values[i];
        }
        double peak=0;foreach(double n in totals.Values)peak=Math.Max(peak,n);return totals.Count==0?(double?)null:Math.Min(100,peak);
    }
    static double? Gpu(IntPtr counter){
        if(counter==IntPtr.Zero)return null;uint bytes=0,count;uint result=PdhGetFormattedCounterArrayW(counter,0x8200,ref bytes,out count,IntPtr.Zero);
        if(result!=0x800007d2||bytes==0||bytes>32*1024*1024)return null;
        IntPtr buffer=Marshal.AllocHGlobal((int)bytes);try{
            if(PdhGetFormattedCounterArrayW(counter,0x8200,ref bytes,out count,buffer)!=0)return null;
            var names=new List<string>();var values=new List<double>();int stride=Marshal.SizeOf(typeof(Item));
            for(int i=0;i<count;i++){Item item=(Item)Marshal.PtrToStructure(IntPtr.Add(buffer,i*stride),typeof(Item));if(item.Value.Status>1)continue;names.Add(Marshal.PtrToStringUni(item.Name));values.Add(item.Value.Number);}
            return BusiestEngine(names.ToArray(),values.ToArray());
        }finally{Marshal.FreeHGlobal(buffer);}
    }
    public PcLoadSnapshot Poll(){lock(gate){if(worker==null){worker=new Thread(Run){IsBackground=true,Name="Hub CPU frequency and GPU load"};worker.Start();}return (DateTime.UtcNow-latest.UpdatedUtc).TotalSeconds>4?new PcLoadSnapshot():latest;}}
    void Run(){
        while(!stop.WaitOne(0)){
            IntPtr query=IntPtr.Zero;
            try{
                if(PdhOpenQueryW(null,IntPtr.Zero,out query)!=0)throw new InvalidOperationException("PDH unavailable");
                IntPtr frequency,performance,gpu;
                if(PdhAddEnglishCounterW(query,@"\Processor Information(_Total)\Processor Frequency",IntPtr.Zero,out frequency)!=0)frequency=IntPtr.Zero;
                if(PdhAddEnglishCounterW(query,@"\Processor Information(_Total)\% Processor Performance",IntPtr.Zero,out performance)!=0)performance=IntPtr.Zero;
                if(PdhAddEnglishCounterW(query,@"\GPU Engine(*)\Utilization Percentage",IntPtr.Zero,out gpu)!=0)gpu=IntPtr.Zero;
                PdhCollectQueryData(query);
                while(!stop.WaitOne(1000)){
                    if(PdhCollectQueryData(query)!=0)break;
                    var next=new PcLoadSnapshot();double? mhz=Number(frequency),percent=Number(performance);
                    if(mhz.HasValue&&percent.HasValue&&mhz>0&&percent<=1000){double ghz=mhz.Value*percent.Value/100000;if(ghz<=20){next.CpuGhz=ghz;next.CpuFrequencyPercent=percent;}}
                    next.GpuPercent=Gpu(gpu);next.UpdatedUtc=DateTime.UtcNow;lock(gate){latest=next;}
                }
            }catch{lock(gate){latest=new PcLoadSnapshot();}}
            finally{if(query!=IntPtr.Zero)PdhCloseQuery(query);}
            if(stop.WaitOne(2000))break;
        }
    }
    public void Dispose(){stop.Set();if(worker!=null&&!worker.Join(2500))return;stop.Dispose();}
}
public sealed class PcSampler {
    [StructLayout(LayoutKind.Sequential)] struct Memory {
        public uint length, load;
        public ulong totalPhysical, availablePhysical, totalPage, availablePage, totalVirtual, availableVirtual, extended;
    }
    [DllImport("kernel32", SetLastError=true)] static extern bool GetSystemTimes(out long idle,out long kernel,out long user);
    [DllImport("kernel32", SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref Memory memory);
    long oldIdle,oldKernel,oldUser; bool cpuReady;
    public static double? CpuDelta(long idle,long kernel,long user) {
        double total=(double)kernel+user;
        if(idle<0||kernel<0||user<0||total<=0||idle>total)return null;
        return Math.Max(0,Math.Min(100,100*(total-idle)/total));
    }
    public PcSnapshot Sample() {
        var result=new PcSnapshot(); long idle,kernel,user;
        if(GetSystemTimes(out idle,out kernel,out user)) {
            if(cpuReady)result.CpuPercent=CpuDelta(idle-oldIdle,kernel-oldKernel,user-oldUser);
            oldIdle=idle;oldKernel=kernel;oldUser=user;cpuReady=true;
        }else cpuReady=false;
        Memory m=new Memory();m.length=(uint)Marshal.SizeOf(typeof(Memory));
        if(GlobalMemoryStatusEx(ref m)&&m.totalPhysical>0) {
            result.TotalMemoryGiB=m.totalPhysical/1073741824.0;
            result.UsedMemoryGiB=(m.totalPhysical-m.availablePhysical)/1073741824.0;
            result.MemoryPercent=100.0*(m.totalPhysical-m.availablePhysical)/m.totalPhysical;
        }
        return result;
    }
}
