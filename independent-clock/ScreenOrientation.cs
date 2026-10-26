using System;
using System.Drawing;
using System.Drawing.Drawing2D;
public static class ScreenOrientation {
    public static Bitmap Apply(Bitmap source,int degrees,bool whiteBackground){
        return Apply(source,degrees,whiteBackground,false);
    }
    public static Bitmap Apply(Bitmap source,int degrees,bool whiteBackground,bool mirror){
        if(degrees!=0&&degrees!=90&&degrees!=180&&degrees!=270)throw new ArgumentException("Invalid rotation");
        int width=source.Width,height=source.Height;
        using(var rotated=(Bitmap)source.Clone()){
            rotated.RotateFlip(degrees==90?RotateFlipType.Rotate90FlipNone:degrees==180?RotateFlipType.Rotate180FlipNone:degrees==270?RotateFlipType.Rotate270FlipNone:RotateFlipType.RotateNoneFlipNone);
            if(mirror)rotated.RotateFlip(RotateFlipType.RotateNoneFlipX);
            var result=new Bitmap(width,height);
            using(var g=Graphics.FromImage(result)){
                g.Clear(whiteBackground?Color.White:Color.FromArgb(13,17,21));
                g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                double scale=Math.Min(width/(double)rotated.Width,height/(double)rotated.Height);
                int w=(int)Math.Round(rotated.Width*scale),h=(int)Math.Round(rotated.Height*scale);
                if(w==width&&h==height)g.DrawImageUnscaled(rotated,0,0);
                else g.DrawImage(rotated,new Rectangle((width-w)/2,(height-h)/2,w,h));
            }
            return result;
        }
    }
}
