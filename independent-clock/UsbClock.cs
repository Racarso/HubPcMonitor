using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public sealed class HubUsb : IDisposable {
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint period);
    const string Dll = "libusb-1.0.dll";
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr LoadLibrary(string path);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_init(out IntPtr context);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern void libusb_exit(IntPtr context);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern IntPtr libusb_get_device_list(IntPtr context, out IntPtr list);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern void libusb_free_device_list(IntPtr list, int unref);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_get_device_descriptor(IntPtr device, [Out] byte[] descriptor);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_open(IntPtr device, out IntPtr handle);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern void libusb_close(IntPtr handle);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_get_string_descriptor_ascii(IntPtr handle, byte index, [Out] byte[] data, int length);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_get_active_config_descriptor(IntPtr device, out IntPtr config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern void libusb_free_config_descriptor(IntPtr config);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_claim_interface(IntPtr handle, int number);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_set_interface_alt_setting(IntPtr handle, int number, int alternate);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_release_interface(IntPtr handle, int number);
    [DllImport(Dll, CallingConvention=CallingConvention.Cdecl)] static extern int libusb_bulk_transfer(IntPtr handle, byte endpoint, [In,Out] byte[] data, int length, out int transferred, uint timeout);
    [StructLayout(LayoutKind.Sequential)] struct Config {
        public byte length, type; public ushort total; public byte count, value, name, attributes, power;
        public IntPtr interfaces, extra; public int extraLength;
    }
    [StructLayout(LayoutKind.Sequential)] struct Interface { public IntPtr alternates; public int count; }
    [StructLayout(LayoutKind.Sequential)] struct Alternate {
        public byte length,type,number,alternate,count,cls,subclass,protocol,name;
        public IntPtr endpoints,extra; public int extraLength;
    }
    [StructLayout(LayoutKind.Sequential)] struct Endpoint {
        public byte length,type,address,attributes; public ushort packetSize;
        public byte interval,refresh,sync; public IntPtr extra; public int extraLength;
    }
    IntPtr context, handle; bool claimed, uncertain, live;
    byte input, output; int interfaceNumber;
    public string Serial {get; private set;}
    public string Identity {get; private set;}
    public string LastReply {get; private set;}
    public string Firmware {get; private set;}
    public int? VoltageMillivolts {get;private set;}
    public DateTime VoltageUpdatedUtc {get;private set;}
    public static int? ParseVoltage(string reply) {
        Match m=Regex.Match(reply??"","^PONG,([0-9]+)$");int mv;
        return m.Success&&Int32.TryParse(m.Groups[1].Value,out mv)&&mv>0&&mv<=65535?(int?)mv:null;
    }
    public static bool ConfirmLegacyApplication(string identity,string firmware,bool liveExitConfirmed){
        return Regex.IsMatch(identity??"","^JED,[0-9A-Fa-f]{6},[0-9]+,[0-9.]+,[0-9.]+,[0-9]+$")&&
            ((firmware??"").Contains(",app,")||(firmware=="FW,1,err,busy"&&liveExitConfirmed));
    }
    public int? QueryVoltage() {
        VoltageMillivolts=null;VoltageUpdatedUtc=DateTime.MinValue;
        Write(new byte[]{165,90,9});
        try {VoltageMillivolts=ParseVoltage(ReadReply("PONG",350));}
        catch(TimeoutException) {return null;}
        if(VoltageMillivolts.HasValue)VoltageUpdatedUtc=DateTime.UtcNow;
        return VoltageMillivolts;
    }
    public string HardwareVariant {get;private set;}
    public string IdentitySource {get;private set;}
    public int Width {get; private set;}
    public int Height {get; private set;}
    public long Frames {get; private set;}
    public long RegionFrames {get;private set;}
    public long PixelBytes {get;private set;}
    public string Diagnostics {get; private set;}
    public HubUsb() { Check(libusb_init(out context), "Initialize USB"); }
    static void Check(int code, string operation) {
        if(code < 0) throw new InvalidOperationException(operation+" failed (libusb "+code+"). Close the vendor GUI and other USB apps. Check device and driver; this app does not install drivers.");
    }
    static T Read<T>(IntPtr address) { return (T)Marshal.PtrToStructure(address, typeof(T)); }
    string ReadSerial(IntPtr h, byte index) {
        byte[] data=new byte[256]; int size=libusb_get_string_descriptor_ascii(h,index,data,data.Length);
        return size>0 ? Encoding.ASCII.GetString(data,0,size).Trim().ToUpperInvariant() : "";
    }
    public string[] ListDevices() {
        IntPtr list; long count=libusb_get_device_list(context,out list).ToInt64();
        if(count<0) throw new InvalidOperationException("USB enumeration failed: "+count);
        var result=new List<string>(); var notes=new List<string>();
        try { for(int i=0;i<count;i++) {
            IntPtr device=Marshal.ReadIntPtr(list,i*IntPtr.Size); byte[] descriptor=new byte[18];
            if(libusb_get_device_descriptor(device,descriptor)<0 || !Supported(descriptor)) continue;
            IntPtr h; int opened=libusb_open(device,out h);
            if(opened<0) {notes.Add("Supported VID/PID found but open failed: libusb "+opened);continue;}
            try { string sn=ReadSerial(h,descriptor[16]); if(ValidSerial(sn)) result.Add(sn);else notes.Add("Device opened but complete SN unavailable."); }
            finally { libusb_close(h); }
        }} finally { libusb_free_device_list(list,1); }
        Diagnostics="USB devices enumerated: "+count+". "+String.Join("; ",notes.ToArray());
        return result.ToArray();
    }
    static bool Supported(byte[] d) { int vid=d[8]|d[9]<<8,pid=d[10]|d[11]<<8; return vid==0x0483 && (pid==0x66AA || pid==0x66AB); }
    static bool ValidSerial(string sn) { return Regex.IsMatch(sn,"^[0-9A-F]{24}$") && sn!=new string('0',24) && sn!=new string('F',24); }
    public void Connect(string serial) { Connect(serial,"Auto"); }
    public void Connect(string serial,string model) {Connect(serial,model,model);}
    public void Connect(string serial,string model,string legacyModel) {
        if(handle!=IntPtr.Zero) throw new InvalidOperationException("Already connected.");
        serial=(serial??"").Trim().ToUpperInvariant();
        if(!ValidSerial(serial)) throw new ArgumentException("Select a complete 24-digit serial number.");
        IntPtr list; long count=libusb_get_device_list(context,out list).ToInt64();
        if(count<0) throw new InvalidOperationException("USB enumeration failed: "+count);
        try { for(int i=0;i<count;i++) {
            IntPtr device=Marshal.ReadIntPtr(list,i*IntPtr.Size); byte[] desc=new byte[18];
            if(libusb_get_device_descriptor(device,desc)<0 || !Supported(desc)) continue;
            IntPtr h; if(libusb_open(device,out h)<0) continue;
            if(ReadSerial(h,desc[16])!=serial) {libusb_close(h);continue;}
            handle=h; Serial=serial;
            try {
                IntPtr ptr; Check(libusb_get_active_config_descriptor(device,out ptr),"Read USB configuration");
                int alternate=0; bool found=false;
                try {
                    Config cfg=Read<Config>(ptr);
                    for(int j=0;j<cfg.count&&!found;j++) {
                        Interface iface=Read<Interface>(IntPtr.Add(cfg.interfaces,j*Marshal.SizeOf(typeof(Interface))));
                        for(int k=0;k<iface.count&&!found;k++) {
                            Alternate a=Read<Alternate>(IntPtr.Add(iface.alternates,k*Marshal.SizeOf(typeof(Alternate))));
                            byte epIn=0,epOut=0;
                            for(int l=0;l<a.count;l++) {
                                Endpoint ep=Read<Endpoint>(IntPtr.Add(a.endpoints,l*Marshal.SizeOf(typeof(Endpoint))));
                                if((ep.attributes&3)!=2) continue;
                                if((ep.address&128)!=0)epIn=ep.address;else epOut=ep.address;
                            }
                            if(epIn!=0&&epOut!=0) {input=epIn;output=epOut;interfaceNumber=a.number;alternate=a.alternate;found=true;}
                        }
                    }
                } finally {libusb_free_config_descriptor(ptr);}
                if(!found)throw new InvalidOperationException("No bulk input/output interface found.");
                Check(libusb_claim_interface(handle,interfaceNumber),"Claim USB interface");claimed=true;
                if(alternate!=0)Check(libusb_set_interface_alt_setting(handle,interfaceNumber,alternate),"Select alternate interface");
                Drain(); Write(new byte[]{165,90,9}); VoltageMillivolts=ParseVoltage(ReadReply("PONG",1800));VoltageUpdatedUtc=VoltageMillivolts.HasValue?DateTime.UtcNow:DateTime.MinValue;
                Drain(); Write(new byte[]{165,90,7});
                Identity=ReadReply("JED,",3000);
                Drain(); Write(new byte[]{165,90,12,1});
                try {Firmware=ReadReply("FW,",2000);} catch(TimeoutException) {Firmware="unavailable";}
                bool liveExitConfirmed=false;
                if(Firmware.Equals("FW,1,err,busy",StringComparison.OrdinalIgnoreCase)){
                    // A previous real-time session can survive host process termination.
                    // Exit only that display mode, then retry the read-only firmware query once.
                    Drain();Write(new byte[]{165,90,11,0,0,0,0,0});
                    string exitReply=ReadReply("LIVE,",2000);
                    if(exitReply!="LIVE,exit")throw new InvalidOperationException("Cannot release busy display session: "+exitReply);
                    liveExitConfirmed=true;
                    System.Threading.Thread.Sleep(300);
                    Drain();Write(new byte[]{165,90,12,1});Firmware=ReadReply("FW,",2000);
                }
                string[] fields=Identity.Split(','); int width,height;
                bool legacy=fields.Length==6;
                if(legacy) {
                    if(legacyModel!="V1PRO"&&legacyModel!="V2")throw new InvalidOperationException("Legacy firmware does not report model or panel size. Confirm this SN in device-profiles.json first. "+Identity);
                    if(!ConfirmLegacyApplication(Identity,Firmware,liveExitConfirmed))throw new InvalidOperationException("Unconfirmed legacy application firmware. JED="+Identity+"; FW="+Firmware);
                    width=320;height=legacyModel=="V1PRO"?170:240;
                } else if(fields.Length<8 || !Int32.TryParse(fields[6],out width) || !Int32.TryParse(fields[7],out height)) throw new InvalidOperationException("Device did not report explicit panel dimensions: "+Identity+"; "+Firmware);
                var variants=new HashSet<string>();
                foreach(string field in fields)if(field.StartsWith("HW="))variants.Add(field.Substring(3).Trim().ToUpperInvariant());
                if(legacy)variants.Add(legacyModel=="V1PRO"?"V1P":"V2");
                if(variants.Count!=1 || !(variants.Contains("V1P")||variants.Contains("V2")) || width!=320 || (variants.Contains("V1P")?height!=170:height!=240))
                    throw new InvalidOperationException("Unconfirmed/unsupported hardware identity: "+Identity);
                if(!legacy && model!="Auto" && ((model=="V1PRO")!=variants.Contains("V1P")))throw new InvalidOperationException("Selected model conflicts with reported hardware.");
                HardwareVariant=variants.Contains("V1P")?"V1P":"V2";IdentitySource=legacy?"Confirmed serial profile":"Device reported";
                Width=width;Height=height;Frames=0;RegionFrames=0;PixelBytes=0;uncertain=false;live=false;return;
            }catch {Close();throw;}
        }} finally {libusb_free_device_list(list,1);}
        throw new InvalidOperationException("Selected device unavailable. Check USB connection and close vendor GUI.");
    }
    void Drain() { for(int i=0;i<8;i++){byte[] b=new byte[64];int done;int code=libusb_bulk_transfer(handle,input,b,64,out done,20);if(code==-7||done==0)break;Check(code,"Drain USB");} }
    void Write(byte[] packet) {
        if(handle==IntPtr.Zero||uncertain)throw new InvalidOperationException("USB session unavailable; reconnect.");
        for(int offset=0;offset<packet.Length;offset+=4096){
            int size=Math.Min(4096,packet.Length-offset),done;byte[] chunk=new byte[size];Buffer.BlockCopy(packet,offset,chunk,0,size);
            int code=libusb_bulk_transfer(handle,output,chunk,size,out done,3000);
            if(code<0||done!=size){uncertain=true;throw new InvalidOperationException("USB write incomplete ("+code+", "+done+"/"+size+"). Session stopped; reconnect device.");}
        }
    }
    string ReadReply(string prefix,int timeout) {
        Stopwatch watch=Stopwatch.StartNew();
        while(watch.ElapsedMilliseconds<timeout){
            byte[] data=new byte[64];int done;int code=libusb_bulk_transfer(handle,input,data,64,out done,(uint)Math.Max(1,Math.Min(400,timeout-watch.ElapsedMilliseconds)));
            if(code==-7)continue;Check(code,"Read USB reply");
            string text=Encoding.ASCII.GetString(data,0,done).Replace("\0","").Trim();
            if(text.StartsWith(prefix,StringComparison.Ordinal)){LastReply=text;return text;}
            if(text.StartsWith("ERR")||text.StartsWith("LIVE,err,"))throw new InvalidOperationException("Device rejected command: "+text);
        }
        throw new TimeoutException("No device reply for "+prefix);
    }
    public static byte[] BuildFrame(byte[] pixels,int width,int height) {
        if(width<=0||height<=0||width>1024||height>1024||pixels==null||pixels.Length!=width*height*2)throw new ArgumentException("Invalid RGB565 frame length.");
        byte[] result=new byte[8+pixels.Length];result[0]=165;result[1]=90;result[2]=11;
        int size=pixels.Length;for(int i=0;i<4;i++)result[3+i]=(byte)(size>>(8*i));
        Buffer.BlockCopy(pixels,0,result,8,size);return result;
    }
    public static byte[] BgraToRgb565(byte[] bgra,int width,int height,int stride) {
        if(stride<width*4||bgra.Length<stride*height)throw new ArgumentException("Invalid bitmap stride.");
        byte[] rgb=new byte[width*height*2];
        for(int y=0;y<height;y++)for(int x=0;x<width;x++){
            int p=y*stride+x*4,q=(y*width+x)*2;
            int pixel=((bgra[p+2]>>3)<<11)|((bgra[p+1]>>2)<<5)|(bgra[p]>>3);
            rgb[q]=(byte)(pixel>>8);rgb[q+1]=(byte)pixel;
        }return rgb;
    }
    public void SendFrame(byte[] pixels) {
        try {Write(BuildFrame(pixels,Width,Height));live=true;
            string reply=ReadReply("LIVE,",3000);if(reply!="LIVE,ok")throw new InvalidOperationException("Unexpected LIVE reply: "+reply);Frames++;PixelBytes+=pixels.Length;
        }catch{uncertain=true;throw;}
    }
    public static byte[] Crop(byte[] full,int panelWidth,int panelHeight,int x,int y,int width,int height) {
        if(full==null||full.Length!=panelWidth*panelHeight*2||x<0||y<0||width<=0||height<=0||x+width>panelWidth||y+height>panelHeight)throw new ArgumentException("Invalid crop.");
        byte[] pixels=new byte[width*height*2];
        for(int row=0;row<height;row++)Buffer.BlockCopy(full,((y+row)*panelWidth+x)*2,pixels,row*width*2,width*2);
        return pixels;
    }
    public static byte[] BuildRegion(byte[] pixels,int panelWidth,int panelHeight,int x,int y,int width,int height) {
        if(pixels==null||pixels.Length!=width*height*2||x<0||y<0||width<=0||height<=0||x+width>panelWidth||y+height>panelHeight||panelWidth>1024||panelHeight>1024)throw new ArgumentException("Invalid LIVE region.");
        byte[] packet=new byte[16+pixels.Length];packet[0]=165;packet[1]=90;packet[2]=11;packet[7]=1;
        int length=pixels.Length;for(int i=0;i<4;i++)packet[3+i]=(byte)(length>>(8*i));
        int[] rect={x,y,width,height};for(int i=0;i<4;i++){packet[8+i*2]=(byte)rect[i];packet[9+i*2]=(byte)(rect[i]>>8);}
        Buffer.BlockCopy(pixels,0,packet,16,pixels.Length);return packet;
    }
    public void SendRegion(byte[] pixels,int x,int y,int width,int height) {
        if(!live)throw new InvalidOperationException("Initialize full screen before region updates.");
        try {Write(BuildRegion(pixels,Width,Height,x,y,width,height));
            string reply=ReadReply("LIVE,",3000);if(reply!="LIVE,ok")throw new InvalidOperationException("Unexpected region reply: "+reply);Frames++;RegionFrames++;PixelBytes+=pixels.Length;
        }catch{uncertain=true;throw;}
    }
    public static int[] DirtyBounds(byte[] previous,byte[] current,int width,int height,int top,int bottom) {
        if(previous==null||current==null||previous.Length!=width*height*2||current.Length!=previous.Length||top<0||bottom>height||top>=bottom)throw new ArgumentException("Invalid dirty frame.");
        int left=width,right=-1,minY=bottom,maxY=-1;
        for(int y=top;y<bottom;y++)for(int x=0;x<width;x++){
            int p=(y*width+x)*2;
            if(previous[p]!=current[p]||previous[p+1]!=current[p+1]){left=Math.Min(left,x);right=Math.Max(right,x);minY=Math.Min(minY,y);maxY=y;}
        }
        return right<0?null:new int[]{left,minY,right-left+1,maxY-minY+1};
    }
    public void SendDirty(byte[] current,byte[] previous) {
        if(previous==null){SendFrame(current);return;}
        int bar=(int)(65*Height/170.0),temp=(int)(102*Height/170.0);int[] boundaries={0,12,16,40,bar,bar+(int)(7*Height/170.0),temp,temp+(int)(7*Height/170.0),Height};
        for(int i=0;i<boundaries.Length-1;i++){
            int[] rect=DirtyBounds(previous,current,Width,Height,boundaries[i],boundaries[i+1]);
            if(rect!=null)SendRegion(Crop(current,Width,Height,rect[0],rect[1],rect[2],rect[3]),rect[0],rect[1],rect[2],rect[3]);
        }
    }
    public static int[][] AnimationRegions(byte[] current,byte[] previous,int width,int height){
        if(previous==null||current==null||current.Length!=width*height*2||previous.Length!=current.Length)throw new ArgumentException("Invalid animation frame");
        var rects=new List<int[]>();
        for(int top=0;top<height;top+=16){
            int bottom=Math.Min(height,top+16),run=-1;
            for(int left=0;left<=width;left+=16){
                bool changed=false;
                if(left<width)for(int y=top;y<bottom&&!changed;y++)for(int x=left;x<Math.Min(width,left+16);x++){
                    int p=(y*width+x)*2;if(current[p]!=previous[p]||current[p+1]!=previous[p+1]){changed=true;break;}
                }
                if(changed&&run<0)run=left;
                if(!changed&&run>=0){
                    int minX=left,maxX=run,minY=bottom,maxY=top-1;
                    for(int y=top;y<bottom;y++)for(int x=run;x<Math.Min(left,width);x++){
                        int p=(y*width+x)*2;if(current[p]!=previous[p]||current[p+1]!=previous[p+1]){minX=Math.Min(minX,x);maxX=Math.Max(maxX,x);minY=Math.Min(minY,y);maxY=Math.Max(maxY,y);}
                    }
                    if(maxY>=minY)rects.Add(new int[]{minX,minY,maxX-minX+1,maxY-minY+1});run=-1;
                }
            }
            // Flush a changed run touching the right edge when width is not a multiple of 16.
            if(run>=0)rects.Add(new int[]{run,top,width-run,bottom-top});
        }
        while(true){
            int best=-1,other=-1;long savings=0;int[] merged=null;
            for(int i=0;i<rects.Count;i++)for(int j=i+1;j<rects.Count;j++){
                int[] a=rects[i],b=rects[j];int x=Math.Min(a[0],b[0]),y=Math.Min(a[1],b[1]);
                int w=Math.Max(a[0]+a[2],b[0]+b[2])-x,h=Math.Max(a[1]+a[3],b[1]+b[3])-y;
                long gain=768L+2L*a[2]*a[3]+2L*b[2]*b[3]-2L*w*h;
                if(gain>savings){savings=gain;best=i;other=j;merged=new int[]{x,y,w,h};}
            }
            if(best<0)break;rects[best]=merged;rects.RemoveAt(other);
        }
        return rects.ToArray();
    }
    public byte[] SendSpectrum(byte[] current,byte[] sent){
        SendAnimation(current,sent);
        return (byte[])current.Clone();
    }
    public void SendAnimation(byte[] current,byte[] previous){
        if(previous==null){SendFrame(current);return;}
        foreach(int[] r in AnimationRegions(current,previous,Width,Height))SendRegion(Crop(current,Width,Height,r[0],r[1],r[2],r[3]),r[0],r[1],r[2],r[3]);
    }
    public static byte[] FilterAnimation(byte[] current,byte[] sent,int threshold){
        if(current==null||sent==null||current.Length!=sent.Length||current.Length%2!=0||threshold<0||threshold>32)throw new ArgumentException("Invalid animation filter");
        var candidate=(byte[])current.Clone();
        for(int i=0;i<current.Length;i+=2){
            int a=current[i]<<8|current[i+1],b=sent[i]<<8|sent[i+1];
            if(Math.Abs((a>>11)-(b>>11))*8<=threshold&&Math.Abs(((a>>5)&63)-((b>>5)&63))*4<=threshold&&Math.Abs((a&31)-(b&31))*8<=threshold){candidate[i]=sent[i];candidate[i+1]=sent[i+1];}
        }
        return candidate;
    }
    public static byte[] QuantizeRgb565(byte[] pixels,int redBits,int greenBits,int blueBits){
        if(pixels==null||pixels.Length%2!=0||redBits<1||redBits>5||greenBits<1||greenBits>6||blueBits<1||blueBits>5)throw new ArgumentException("Invalid color quantization");
        int rl=(1<<redBits)-1,gl=(1<<greenBits)-1,bl=(1<<blueBits)-1;
        var result=new byte[pixels.Length];
        for(int i=0;i<pixels.Length;i+=2){
            int p=pixels[i]<<8|pixels[i+1],r=p>>11,g=(p>>5)&63,b=p&31;
            r=(((r*rl+15)/31)*31+rl/2)/rl;
            g=(((g*gl+31)/63)*63+gl/2)/gl;
            b=(((b*bl+15)/31)*31+bl/2)/bl;
            p=(r<<11)|(g<<5)|b;result[i]=(byte)(p>>8);result[i+1]=(byte)p;
        }
        return result;
    }
    public byte[] SendAnimationFiltered(byte[] current,byte[] sent,int threshold){
        if(sent==null){SendFrame(current);return (byte[])current.Clone();}
        var candidate=FilterAnimation(current,sent,threshold);
        foreach(int[] r in AnimationRegions(candidate,sent,Width,Height)){
            SendRegion(Crop(current,Width,Height,r[0],r[1],r[2],r[3]),r[0],r[1],r[2],r[3]);
            // Commit only pixels whose containing rectangle was acknowledged by the device.
            for(int y=r[1];y<r[1]+r[3];y++)Buffer.BlockCopy(current,(y*Width+r[0])*2,sent,(y*Width+r[0])*2,r[2]*2);
        }
        return sent;
    }
    public static double AnimationLogicalY(int x,int y,int width,int height,int rotation){
        if(rotation==0)return (y+0.5)/height;
        if(rotation==180)return 1-(y+0.5)/height;
        if(rotation!=90&&rotation!=270)throw new ArgumentException("Invalid rotation");
        double scale=Math.Min(width/(double)height,height/(double)width);
        int drawWidth=(int)Math.Round(height*scale),left=(width-drawWidth)/2;
        double u=(x-left+0.5)/drawWidth;
        return rotation==90?1-u:u;
    }
    public static byte[] FilterAnimationZoned(byte[] current,byte[] sent,int width,int height,bool reduced,int rotation,int exactTop,int exactRows){
        if(width<=0||height<=0||current==null||sent==null||current.Length!=width*height*2||sent.Length!=current.Length||exactRows<0||exactTop<0||exactTop+exactRows>height)throw new ArgumentException("Invalid zoned animation");
        var candidate=(byte[])current.Clone();
        for(int y=0;y<height;y++)for(int x=0;x<width;x++){
            if(exactRows>0&&y>=exactTop&&y<exactTop+exactRows)continue;
            double logicalY=AnimationLogicalY(x,y,width,height,rotation);
            int threshold=logicalY>=0.60?(reduced?32:16):logicalY>=0.35?(reduced?40:20):(reduced?48:24);
            int i=(y*width+x)*2,a=current[i]<<8|current[i+1],b=sent[i]<<8|sent[i+1];
            if(Math.Abs((a>>11)-(b>>11))*8<=threshold&&Math.Abs(((a>>5)&63)-((b>>5)&63))*4<=threshold&&Math.Abs((a&31)-(b&31))*8<=threshold){candidate[i]=sent[i];candidate[i+1]=sent[i+1];}
        }
        return candidate;
    }
    public byte[] SendAnimationZoned(byte[] current,byte[] sent,bool reduced,int rotation,int exactTop,int exactRows){
        if(sent==null){SendFrame(current);return (byte[])current.Clone();}
        var candidate=FilterAnimationZoned(current,sent,Width,Height,reduced,rotation,exactTop,exactRows);
        foreach(int[] r in AnimationRegions(candidate,sent,Width,Height)){
            SendRegion(Crop(current,Width,Height,r[0],r[1],r[2],r[3]),r[0],r[1],r[2],r[3]);
            for(int y=r[1];y<r[1]+r[3];y++)Buffer.BlockCopy(current,(y*Width+r[0])*2,sent,(y*Width+r[0])*2,r[2]*2);
        }
        return sent;
    }
    public void Close() {
        VoltageMillivolts=null;VoltageUpdatedUtc=DateTime.MinValue;
        if(handle==IntPtr.Zero)return;
        try {if(live&&!uncertain){Write(new byte[]{165,90,11,0,0,0,0,0});string reply=ReadReply("LIVE,",2000);if(reply!="LIVE,exit")throw new InvalidOperationException("Unexpected exit reply: "+reply);}}
        finally {if(claimed)libusb_release_interface(handle,interfaceNumber);libusb_close(handle);handle=IntPtr.Zero;claimed=false;live=false;uncertain=false;}
    }
    public void Dispose(){try{Close();}finally{if(context!=IntPtr.Zero){libusb_exit(context);context=IntPtr.Zero;}}}
}

public sealed class HubReconnectState {
    public bool Wanted {get;private set;}
    public string TargetSerial {get;private set;}
    DateTime nextAttempt=DateTime.MinValue;
    public HubReconnectState(){Wanted=true;}
    public void Start(string serial){Wanted=true;if(!String.IsNullOrEmpty(serial))TargetSerial=serial;nextAttempt=DateTime.MinValue;}
    public void Stop(){Wanted=false;}
    public void Failed(DateTime now){nextAttempt=now.AddSeconds(3);}
    public bool ShouldAttempt(DateTime now,bool running){return Wanted&&!running&&now>=nextAttempt;}
    public string SelectTarget(string[] serials){
        if(!String.IsNullOrEmpty(TargetSerial)){foreach(string serial in serials)if(String.Equals(serial,TargetSerial,StringComparison.OrdinalIgnoreCase))return serial;return null;}
        return serials.Length==1?serials[0]:null;
    }
}
