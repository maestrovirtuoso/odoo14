param([string]$ProjectRoot,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$xml=[xml][IO.File]::ReadAllText((Join-Path $ProjectRoot 'docs/architecture-reseau-lxc.drawio'))
$vertices=@{};$edges=@()
foreach($cell in $xml.SelectNodes('//mxCell[@vertex="1" or @edge="1"]')){
 $style=@{};foreach($part in $cell.style.Split(';')){if($part -match '^([^=]+)=(.*)$'){$style[$matches[1]]=$matches[2]}}
 if($cell.vertex -eq '1'){$g=$cell.mxGeometry;$vertices[$cell.id]=[pscustomobject]@{Id=$cell.id;X=[double]$g.x;Y=[double]$g.y;W=[double]$g.width;H=[double]$g.height;Text=[string]$cell.value;Style=$style}}
 else{$edges+=,[pscustomobject]@{Id=$cell.id;Source=$cell.source;Target=$cell.target;Text=[string]$cell.value;Style=$style}}
}
$bitmap=[Drawing.Bitmap]::new(3000,2500)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$graphics.ScaleTransform(2,2)
$graphics.Clear([Drawing.Color]::White)
$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
function HtmlColor($hex){[Drawing.ColorTranslator]::FromHtml($hex)}
function Label($text,$x,$y,$w,$h,$size=12,$color='#263544',$left=$false){
 $font=[Drawing.Font]::new('Segoe UI',[single]$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
 $brush=[Drawing.SolidBrush]::new((HtmlColor $color))
 $format=[Drawing.StringFormat]::new()
 $format.Alignment=if($left){[Drawing.StringAlignment]::Near}else{[Drawing.StringAlignment]::Center}
 $format.LineAlignment=[Drawing.StringAlignment]::Center
 $graphics.DrawString($text,$font,$brush,[Drawing.RectangleF]::new($x,$y,$w,$h),$format)
 $format.Dispose();$font.Dispose();$brush.Dispose()
}
$edgeLabels=@()
foreach($edge in $edges){
 $s=$vertices[$edge.Source];$t=$vertices[$edge.Target]
 $sx=$s.X+$s.W/2;$sy=$s.Y+$s.H/2;$tx=$t.X+$t.W/2;$ty=$t.Y+$t.H/2
 if($t.Y -ge $s.Y+$s.H){
  $ax=[Math]::Max($s.X+10,[Math]::Min($tx,$s.X+$s.W-10));$bx=[Math]::Max($t.X+10,[Math]::Min($ax,$t.X+$t.W-10))
  $ay=$s.Y+$s.H;$by=$t.Y;$mid=($ay+$by)/2
  $pts=@(@($ax,$ay),@($ax,$mid),@($bx,$mid),@($bx,$by))
  $label=@((($ax+$bx)/2-210),($mid-12),420,24)
 } else {
  $ax=$s.X+$s.W;$bx=$t.X;$mid=($ax+$bx)/2
  $pts=@(@($ax,$sy),@($mid,$sy),@($mid,$ty),@($bx,$ty));$label=@(($mid-200),($sy-28),400,24)
 }
 if($edge.Id -eq 'route1'){$pts=@(@(1460,300),@(1480,300),@(1480,640),@(1020,640));$label=@(1050,604,400,26)}
 if($edge.Id -eq 'repl2'){$pts=@(@(270,995),@(270,1040),@(745,1040),@(745,995));$label=@(315,1022,700,16)}
 if($edge.Id -eq 'repl3'){$pts=@(@(270,995),@(270,1080),@(1220,1080),@(1220,995));$label=@(1000,1062,390,16)}
 $color=$edge.Style['strokeColor'];if(!$color){$color='#536878'}
 $pen=[Drawing.Pen]::new((HtmlColor $color),1.5)
 if($edge.Style['dashed'] -eq '1'){$pen.DashPattern=[single[]]@(6,4)}
 $pen.CustomEndCap=[Drawing.Drawing2D.AdjustableArrowCap]::new(4,5,$true)
 $points=[Collections.Generic.List[Drawing.PointF]]::new()
 foreach($point in $pts){$next=[Drawing.PointF]::new($point[0],$point[1]);if($points.Count -eq 0 -or $next -ne $points[$points.Count-1]){$points.Add($next)}}
 $graphics.DrawLines($pen,$points.ToArray());$pen.Dispose()
 $edgeLabels+=,[pscustomobject]@{Text=$edge.Text;Box=$label;Color=$color;Points=$points.ToArray();Dashed=($edge.Style['dashed'] -eq '1')}
}
foreach($cell in $xml.SelectNodes('//mxCell[@vertex="1"]')){
 $v=$vertices[$cell.id];if($v.Id -eq 'notes'){$v.Y=1110};$fill=$v.Style['fillColor'];if(!$fill){$fill='#FFFFFF'}
 $stroke=$v.Style['strokeColor'];if(!$stroke){$stroke='#536878'}
 $path=[Drawing.Drawing2D.GraphicsPath]::new();$r=12;$d=$r*2
 $path.AddArc([single]$v.X,[single]$v.Y,$d,$d,180,90)
 $path.AddArc([single]($v.X+$v.W-$d),[single]$v.Y,$d,$d,270,90)
 $path.AddArc([single]($v.X+$v.W-$d),[single]($v.Y+$v.H-$d),$d,$d,0,90)
 $path.AddArc([single]$v.X,[single]($v.Y+$v.H-$d),$d,$d,90,90);$path.CloseFigure()
 $brush=[Drawing.SolidBrush]::new((HtmlColor $fill));$pen=[Drawing.Pen]::new((HtmlColor $stroke),1.2)
 $graphics.FillPath($brush,$path);$graphics.DrawPath($pen,$path)
 $fontSize=14
 if($v.Id -like 'host*'){Label $v.Text ($v.X+6) ($v.Y+3) ($v.W-12) 49 $fontSize}
 else{Label $v.Text ($v.X+8) ($v.Y+5) ($v.W-16) ($v.H-10) $fontSize '#263544' ($v.Id -eq 'notes')}
 $path.Dispose();$brush.Dispose();$pen.Dispose()
}
foreach($item in $edgeLabels){
 $pen=[Drawing.Pen]::new((HtmlColor $item.Color),1.5)
 if($item.Dashed){$pen.DashPattern=[single[]]@(6,4)}
 $pen.CustomEndCap=[Drawing.Drawing2D.AdjustableArrowCap]::new(4,5,$true)
 $graphics.DrawLines($pen,$item.Points);$pen.Dispose()
}
foreach($item in $edgeLabels){$b=$item.Box;$graphics.FillRectangle([Drawing.Brushes]::White,[Drawing.RectangleF]::new($b[0],$b[1],$b[2],$b[3]));Label $item.Text $b[0] $b[1] $b[2] $b[3] 11 $item.Color}
$target=Join-Path $OutputDirectory 'architecture-reseau-lxc-historique.png'
$bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose();$bitmap.Dispose()
Write-Output 'Export du diagramme reseau historique : 3000 x 2500.'
