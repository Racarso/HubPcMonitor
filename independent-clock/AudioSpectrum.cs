using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;

// Shared-mode WASAPI loopback: capture default playback, never microphone input.
public sealed class AudioSpectrum : IDisposable {
    const int N=2048, Bands=24;
    static readonly double[] Window=MakeWindow();
    static double[] MakeWindow(){var w=new double[N];for(int i=0;i<N;i++)w[i]=.5-.5*Math.Cos(2*Math.PI*i/(N-1));return w;}
    readonly object gate=new object();
    readonly double[] ring=new double[N];
    double[] levels=new double[Bands];
    int write,count,rate;
    Thread worker; ManualResetEvent stop;
    string status="WAITING"; DateTime updated;
    public long CapturedFrames {get;private set;}
    public double SamplePeak {get;private set;}
    public string Format {get;private set;}
    public string OutputVolume {get;private set;}
    public void Start(){if(worker!=null)return;stop=new ManualResetEvent(false);worker=new Thread(Run){IsBackground=true,Name="Hub WASAPI spectrum"};worker.SetApartmentState(ApartmentState.MTA);worker.Start();}
    public void Stop(){if(worker==null)return;stop.Set();if(!worker.Join(2500))throw new InvalidOperationException("Audio capture did not stop");worker=null;stop.Dispose();stop=null;lock(gate){levels=new double[Bands];status="WAITING";}}
    public void Dispose(){Stop();}
    public string Status{get{lock(gate)return status;}}
    public double[] Snapshot(){lock(gate){var copy=(double[])levels.Clone();double age=(DateTime.UtcNow-updated).TotalSeconds;if(age>.12){double decay=Math.Exp(-(age-.12)*8);for(int i=0;i<copy.Length;i++)copy[i]*=decay;}return copy;}}
    static void Check(int hr){Marshal.ThrowExceptionForHR(hr);}
    static void Release(object obj){if(obj!=null&&Marshal.IsComObject(obj))Marshal.ReleaseComObject(obj);}
    void Run(){
        while(!stop.WaitOne(0)){
            IMMDeviceEnumerator devices=null;IMMDevice device=null;IAudioClient audio=null;IAudioCaptureClient capture=null;IntPtr format=IntPtr.Zero;bool started=false;
            try{
                devices=(IMMDeviceEnumerator)new MMDeviceEnumerator();Check(devices.GetDefaultAudioEndpoint(0,0,out device));
                string endpoint;Check(device.GetId(out endpoint));object obj;Guid iid=typeof(IAudioEndpointVolume).GUID;
                Check(device.Activate(ref iid,23,IntPtr.Zero,out obj));var volume=(IAudioEndpointVolume)obj;try{float scalar;bool muted;Check(volume.GetMasterVolumeLevelScalar(out scalar));Check(volume.GetMute(out muted));OutputVolume="volume="+scalar+", muted="+muted;}finally{Release(volume);}
                iid=typeof(IAudioClient).GUID;Check(device.Activate(ref iid,23,IntPtr.Zero,out obj));audio=(IAudioClient)obj;
                Check(audio.GetMixFormat(out format));short tag=Marshal.ReadInt16(format,0),channels=Marshal.ReadInt16(format,2),align=Marshal.ReadInt16(format,12),bits=Marshal.ReadInt16(format,14);
                rate=Marshal.ReadInt32(format,4);bool floating=tag==3;Format=rate+"Hz / "+channels+"ch / "+bits+"bit / tag "+tag;
                if(tag==unchecked((short)0xfffe)){Guid sub=(Guid)Marshal.PtrToStructure(IntPtr.Add(format,24),typeof(Guid));floating=sub==new Guid("00000003-0000-0010-8000-00aa00389b71");if(!floating&&sub!=new Guid("00000001-0000-0010-8000-00aa00389b71"))throw new NotSupportedException("Unsupported audio format");}
                else if(tag!=1&&tag!=3)throw new NotSupportedException("Unsupported audio format");
                if(channels<1||align<channels||rate<8000||!(bits==16||bits==24||bits==32)||(floating&&bits!=32))throw new NotSupportedException("Unsupported audio sample layout");
                Check(audio.Initialize(0,0x20000,1000000,0,format,IntPtr.Zero));iid=typeof(IAudioCaptureClient).GUID;Check(audio.GetService(ref iid,out obj));capture=(IAudioCaptureClient)obj;
                write=count=0;Array.Clear(ring,0,N);Check(audio.Start());started=true;DateTime nextDevice=DateTime.UtcNow.AddSeconds(2),lastAnalysis=DateTime.MinValue;
                lock(gate){levels=new double[Bands];status="LIVE";updated=DateTime.UtcNow;}
                while(!stop.WaitOne(5)){
                    uint available;Check(capture.GetNextPacketSize(out available));bool data=false;
                    while(available>0){
                        IntPtr buffer;uint frames,flags;ulong pos,qpc;Check(capture.GetBuffer(out buffer,out frames,out flags,out pos,out qpc));
                        try{
                            byte[] bytes=null;if((flags&2)==0){bytes=new byte[checked((int)frames*align)];Marshal.Copy(buffer,bytes,0,bytes.Length);}
                            for(int f=0;f<frames;f++){
                                // Retain the strongest channel so opposite-phase stereo does not cancel.
                                double sample=0;for(int c=0;c<channels&&bytes!=null;c++){double v=Decode(bytes,f*align+c*(bits/8),bits,floating);if(Math.Abs(v)>Math.Abs(sample))sample=v;}
                                SamplePeak=Math.Max(SamplePeak,Math.Abs(sample));ring[write]=sample;write=(write+1)%N;if(count<N)count++;
                            }CapturedFrames+=frames;data=true;
                        }finally{Check(capture.ReleaseBuffer(frames));}
                        Check(capture.GetNextPacketSize(out available));
                    }
                    if(data&&count==N&&(DateTime.UtcNow-lastAnalysis).TotalMilliseconds>=8){var samples=new double[N];for(int i=0;i<N;i++)samples[i]=ring[(write+i)%N];var values=Analyze(samples,rate);lock(gate){levels=values;updated=DateTime.UtcNow;}lastAnalysis=DateTime.UtcNow;}
                    if(DateTime.UtcNow>=nextDevice){IMMDevice current=null;try{Check(devices.GetDefaultAudioEndpoint(0,0,out current));string id;Check(current.GetId(out id));if(id!=endpoint)break;}finally{Release(current);}nextDevice=DateTime.UtcNow.AddSeconds(2);}
                }
            }catch(Exception){lock(gate){levels=new double[Bands];status="NO AUDIO";}}
            finally{if(started)try{audio.Stop();}catch{}if(format!=IntPtr.Zero)Marshal.FreeCoTaskMem(format);Release(capture);Release(audio);Release(device);Release(devices);}
            if(stop.WaitOne(500))break;
        }
    }
    static double Decode(byte[] b,int p,int bits,bool floating){if(floating){double f=BitConverter.ToSingle(b,p);return Double.IsNaN(f)||Double.IsInfinity(f)?0:f;}if(bits==16)return BitConverter.ToInt16(b,p)/32768.0;if(bits==24){int v=b[p]|b[p+1]<<8|b[p+2]<<16;if((v&0x800000)!=0)v|=unchecked((int)0xff000000);return v/8388608.0;}return BitConverter.ToInt32(b,p)/2147483648.0;}
    public static double[] Analyze(double[] samples,int sampleRate){
        if(samples==null||samples.Length!=N||sampleRate<8000)throw new ArgumentException("FFT requires 2048 samples and a valid sample rate");
        double[] re=new double[N],im=new double[N];for(int i=0;i<N;i++)re[i]=samples[i]*Window[i];
        for(int i=1,j=0;i<N;i++){int bit=N>>1;for(;(j&bit)!=0;bit>>=1)j^=bit;j^=bit;if(i<j){double t=re[i];re[i]=re[j];re[j]=t;}}
        for(int len=2;len<=N;len<<=1){double a=-2*Math.PI/len,cr=Math.Cos(a),ci=Math.Sin(a);for(int i=0;i<N;i+=len){double wr=1,wi=0;for(int j=0;j<len/2;j++){int u=i+j,v=u+len/2;double tr=re[v]*wr-im[v]*wi,ti=re[v]*wi+im[v]*wr;re[v]=re[u]-tr;im[v]=im[u]-ti;re[u]+=tr;im[u]+=ti;double next=wr*cr-wi*ci;wi=wr*ci+wi*cr;wr=next;}}}
        double[] result=new double[Bands];double high=Math.Min(16000,sampleRate*.49);
        for(int b=0;b<Bands;b++){int low=Math.Max(1,(int)Math.Floor(50*Math.Pow(high/50,(double)b/Bands)*N/sampleRate));int end=Math.Min(N/2,(int)Math.Ceiling(50*Math.Pow(high/50,(b+1.0)/Bands)*N/sampleRate));double peak=0;for(int k=low;k<Math.Max(low+1,end);k++)peak=Math.Max(peak,Math.Sqrt(re[k]*re[k]+im[k]*im[k])*4/N);double db=20*Math.Log10(Math.Max(1e-9,peak));result[b]=Math.Max(0,Math.Min(1,(db+60)/60));}return result;
    }
    [ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]class MMDeviceEnumerator{}
    [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface IMMDeviceEnumerator{
        [PreserveSig]int EnumAudioEndpoints(int flow,uint mask,out IntPtr devices);
        [PreserveSig]int GetDefaultAudioEndpoint(int flow,int role,out IMMDevice device);
        [PreserveSig]int GetDevice([MarshalAs(UnmanagedType.LPWStr)]string id,out IMMDevice device);
    }
    [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface IMMDevice{
        [PreserveSig]int Activate(ref Guid iid,uint context,IntPtr activation,[MarshalAs(UnmanagedType.IUnknown)]out object obj);
        [PreserveSig]int OpenPropertyStore(int mode,out IntPtr store);
        [PreserveSig]int GetId([MarshalAs(UnmanagedType.LPWStr)]out string id);
        [PreserveSig]int GetState(out uint state);
    }
    [ComImport,Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface IAudioClient{
        [PreserveSig]int Initialize(int mode,uint flags,long duration,long period,IntPtr format,IntPtr session);
        [PreserveSig]int GetBufferSize(out uint size);[PreserveSig]int GetStreamLatency(out long latency);[PreserveSig]int GetCurrentPadding(out uint padding);
        [PreserveSig]int IsFormatSupported(int mode,IntPtr format,out IntPtr closest);[PreserveSig]int GetMixFormat(out IntPtr format);[PreserveSig]int GetDevicePeriod(out long standard,out long minimum);
        [PreserveSig]int Start();[PreserveSig]int Stop();[PreserveSig]int Reset();[PreserveSig]int SetEventHandle(IntPtr handle);
        [PreserveSig]int GetService(ref Guid iid,[MarshalAs(UnmanagedType.IUnknown)]out object obj);
    }
    [ComImport,Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface IAudioCaptureClient{
        [PreserveSig]int GetBuffer(out IntPtr data,out uint frames,out uint flags,out ulong position,out ulong qpc);
        [PreserveSig]int ReleaseBuffer(uint frames);[PreserveSig]int GetNextPacketSize(out uint frames);
    }
    [ComImport,Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface IAudioEndpointVolume{
        [PreserveSig]int RegisterControlChangeNotify(IntPtr notify);[PreserveSig]int UnregisterControlChangeNotify(IntPtr notify);[PreserveSig]int GetChannelCount(out uint count);
        [PreserveSig]int SetMasterVolumeLevel(float level,IntPtr context);[PreserveSig]int SetMasterVolumeLevelScalar(float level,IntPtr context);[PreserveSig]int GetMasterVolumeLevel(out float level);[PreserveSig]int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig]int SetChannelVolumeLevel(uint channel,float level,IntPtr context);[PreserveSig]int SetChannelVolumeLevelScalar(uint channel,float level,IntPtr context);[PreserveSig]int GetChannelVolumeLevel(uint channel,out float level);[PreserveSig]int GetChannelVolumeLevelScalar(uint channel,out float level);
        [PreserveSig]int SetMute([MarshalAs(UnmanagedType.Bool)]bool mute,IntPtr context);[PreserveSig]int GetMute([MarshalAs(UnmanagedType.Bool)]out bool mute);
    }
}

public sealed class TacticalSpectrum {
    readonly double[] smooth=new double[24],peaks=new double[24];DateTime last=DateTime.UtcNow;
    public Bitmap Render(int width,int height,double[] levels,string status,DateTime now){
        double dt=Math.Min(.1,Math.Max(.001,(DateTime.UtcNow-last).TotalSeconds));last=DateTime.UtcNow;
        Bitmap image=new Bitmap(width,height);using(Graphics g=Graphics.FromImage(image)){
            g.ScaleTransform(width/320f,height/170f);g.Clear(Color.FromArgb(13,17,21));
            using(var yellow=new SolidBrush(Color.FromArgb(244,211,94)))using(var gray=new SolidBrush(Color.FromArgb(81,88,94)))using(var white=new SolidBrush(Color.FromArgb(236,239,241)))using(var font=new Font("Consolas",12,FontStyle.Bold,GraphicsUnit.Pixel))using(var time=new Font("Consolas",16,FontStyle.Bold,GraphicsUnit.Pixel))using(var pen=new Pen(Color.FromArgb(244,211,94),1)){
                g.DrawString("AUDIO",font,yellow,10,7);g.DrawString("/ "+status,font,white,49,7);g.DrawString(now.ToString("HH:mm"),time,white,245,5);
                g.DrawLines(pen,new Point[]{new Point(10,25),new Point(100,25),new Point(110,15)});g.FillPolygon(yellow,new Point[]{new Point(302,9),new Point(312,9),new Point(312,20)});
                for(int i=0;i<24;i++){
                    double value=levels!=null&&i<levels.Length?Math.Max(0,Math.Min(1,levels[i])):0;
                    smooth[i]+=(value-smooth[i])*(1-Math.Exp(-dt/(value>smooth[i]?.035:.18)));peaks[i]=Math.Max(smooth[i],peaks[i]-dt*.45);
                    int x=10+i*12;double fill=smooth[i]*115;
                    // Partial top segments remove the old five-pixel height jumps.
                    for(int k=0;k<23;k++){
                        double visible=Math.Max(0,Math.Min(4,fill-k*5));int full=(int)visible;
                        if(full>0)g.FillRectangle(yellow,x,161-k*5-full,9,full);
                        double fraction=visible-full;if(fraction>.01)using(var edge=new SolidBrush(Color.FromArgb((int)(fraction*255),244,211,94)))g.FillRectangle(edge,x,160-k*5-full,9,1);
                    }
                    if(peaks[i]>.035)g.FillRectangle(gray,x,159-(int)Math.Round(peaks[i]*115),9,2);
                }
                g.FillRectangle(yellow,10,164,286,2);g.DrawLines(pen,new Point[]{new Point(302,165),new Point(311,165),new Point(315,160)});
            }
        }return image;
    }
}
