using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class OriginalArtwork {
    // Preserve every foreground pixel. Only connected exterior near-black becomes transparent.
    public static Bitmap RemoveExteriorBackground(Image original) {
        var bitmap=new Bitmap(original.Width,original.Height,PixelFormat.Format32bppArgb);
        using(var graphics=Graphics.FromImage(bitmap))graphics.DrawImageUnscaled(original,0,0);
        int width=bitmap.Width,height=bitmap.Height;
        var bits=bitmap.LockBits(new Rectangle(0,0,width,height),ImageLockMode.ReadWrite,PixelFormat.Format32bppArgb);
        try{
            var pixels=new byte[bits.Stride*height];Marshal.Copy(bits.Scan0,pixels,0,pixels.Length);
            var seen=new bool[width*height];var queue=new int[width*height];int head=0,tail=0;
            Action<int,int> add=(x,y)=>{
                if(x<0||y<0||x>=width||y>=height)return;
                int key=y*width+x,p=y*bits.Stride+x*4;
                if(!seen[key]&&pixels[p]<=32&&pixels[p+1]<=32&&pixels[p+2]<=32){seen[key]=true;queue[tail++]=key;}
            };
            for(int x=0;x<width;x++){add(x,0);add(x,height-1);}
            for(int y=0;y<height;y++){add(0,y);add(width-1,y);}
            while(head<tail){int key=queue[head++],x=key%width,y=key/width;pixels[y*bits.Stride+x*4+3]=0;add(x-1,y);add(x+1,y);add(x,y-1);add(x,y+1);}
            Marshal.Copy(pixels,0,bits.Scan0,pixels.Length);
        }finally{bitmap.UnlockBits(bits);}
        return bitmap;
    }
}
