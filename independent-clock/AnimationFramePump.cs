using System;
using System.Threading;
using System.Windows.Forms;
public sealed class AnimationFramePump:IDisposable {
    readonly Control owner;readonly Action frame;readonly System.Threading.Timer timer;
    int generation;bool disposed;
    public AnimationFramePump(Control control,Action callback){owner=control;frame=callback;timer=new System.Threading.Timer(Tick,null,Timeout.Infinite,Timeout.Infinite);}
    void Tick(object ignored){
        int token=Volatile.Read(ref generation);
        if(disposed||owner.IsDisposed||!owner.IsHandleCreated)return;
        try{owner.BeginInvoke((Action)(()=>{if(!disposed&&token==Volatile.Read(ref generation)&&!owner.IsDisposed)frame();}));}
        catch(InvalidOperationException){}
    }
    public void Schedule(int delay){if(!disposed){Interlocked.Increment(ref generation);timer.Change(Math.Max(1,delay),Timeout.Infinite);}}
    public void Stop(){Interlocked.Increment(ref generation);if(!disposed)timer.Change(Timeout.Infinite,Timeout.Infinite);}
    public void Dispose(){disposed=true;Interlocked.Increment(ref generation);timer.Dispose();}
}
