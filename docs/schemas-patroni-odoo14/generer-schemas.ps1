param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'Dossier de sortie manquant.' }
[void][System.IO.Directory]::CreateDirectory($OutputDirectory)
$script:Pages = [System.Collections.Generic.List[object]]::new()
$script:Bg = '#FFFFFF'
$script:Navy = '#000000'
$script:Blue = '#000000'
$script:Teal = '#000000'
$script:Muted = '#000000'
$script:Border = '#000000'
$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Rect($id,$x,$y,$w,$h,$fill,$stroke='none',$radius=16) {
 [void]$script:Page.Items.Add([pscustomobject]@{Kind='rect';Id=$id;X=$x;Y=$y;W=$w;H=$h;Fill=$fill;Stroke=$stroke;Radius=$radius})
}
function Txt($id,$value,$x,$y,$w,$h,$size=18,$color='#000000',$bold=$false,$align='left') {
 [void]$script:Page.Items.Add([pscustomobject]@{Kind='text';Id=$id;Text=$value.Replace('|',[string][char]10);X=$x;Y=$y;W=$w;H=$h;Size=$size;Color=$color;Bold=$bold;Align=$align})
}
function Arrow($id,$points,$color='#000000',$dashed=$false,$head=$true,$source='',$target='',$width=2.5,$locked=$false) {
 [void]$script:Page.Items.Add([pscustomobject]@{Kind='line';Id=$id;Points=$points;Color=$color;Dashed=$dashed;Head=$head;Source=$source;Target=$target;Width=[double]$width;Locked=[bool]$locked})
}
function Icon($id,$kind,$x,$y,$size=52) {
 $iconScale=$size/64.0
 function IBox($part,$ix,$iy,$iw,$ih,$fill='#FFFFFF') {
  Rect ($id+'-'+$part) ([int][Math]::Round($x+$ix*$iconScale)) ([int][Math]::Round($y+$iy*$iconScale)) ([int][Math]::Round($iw*$iconScale)) ([int][Math]::Round($ih*$iconScale)) $fill '#000000' 0
 }
 function ILine($part,$localPoints) {
  $points=[System.Collections.Generic.List[object]]::new()
  foreach($point in $localPoints) {
   [void]$points.Add(@([int][Math]::Round($x+$point[0]*$iconScale),[int][Math]::Round($y+$point[1]*$iconScale)))
  }
  Arrow ($id+'-'+$part) $points.ToArray() '#000000' $false $false '' '' 2
 }
 function IOval($part,$cx,$cy,$rx,$ry,$start=0,$end=360) {
  $points=[System.Collections.Generic.List[object]]::new()
  for($angle=$start;$angle -le $end;$angle+=15) {
   $radians=$angle*[Math]::PI/180
   [void]$points.Add(@(($cx+$rx*[Math]::Cos($radians)),($cy+$ry*[Math]::Sin($radians))))
  }
  ILine $part $points.ToArray()
 }
 switch($kind) {
  'server' {
   IBox 'rack' 9 5 46 54
   foreach($row in @(12,27,42)) {
    IBox ('drawer-'+$row) 15 $row 34 10
    IBox ('led-'+$row) 20 ($row+4) 3 3 '#000000'
    ILine ('slot-'+$row) @(@(28,($row+5)),@(43,($row+5)))
   }
  }
  'container' {
   ILine 'outline' @(@(9,19),@(32,7),@(55,19),@(55,46),@(32,58),@(9,46),@(9,19))
   ILine 'top' @(@(9,19),@(32,32),@(55,19))
   ILine 'spine' @(@(32,32),@(32,58))
   ILine 'rib-1' @(@(17,29),@(17,45))
   ILine 'rib-2' @(@(24,33),@(24,49))
   ILine 'rib-3' @(@(40,33),@(40,49))
   ILine 'rib-4' @(@(47,29),@(47,45))
  }
  'browser' {
   IBox 'window' 4 8 56 44
   ILine 'toolbar' @(@(4,20),@(60,20))
   foreach($dot in @(11,18,25)) { IBox ('dot-'+$dot) $dot 13 2 2 '#000000' }
   IBox 'content' 12 28 14 15
   ILine 'content-line-1' @(@(33,29),@(52,29))
   ILine 'content-line-2' @(@(33,36),@(52,36))
   ILine 'content-line-3' @(@(33,43),@(47,43))
   ILine 'stand' @(@(32,52),@(32,59))
   ILine 'base' @(@(22,59),@(42,59))
  }
  'nic' {
   IBox 'board' 6 12 50 38
   IBox 'chip' 13 28 12 12
   IBox 'port' 34 23 16 17
   ILine 'port-pins' @(@(38,24),@(38,28),@(46,28),@(46,24))
   ILine 'board-slot' @(@(12,19),@(27,19))
   foreach($pin in @(14,22,30,38,46)) { ILine ('pin-'+$pin) @(@($pin,50),@($pin,58)) }
  }
  'network' {
   IBox 'top' 24 5 16 12
   ILine 'trunk' @(@(32,17),@(32,34))
   ILine 'bus' @(@(11,34),@(53,34))
   foreach($port in @(11,32,53)) {
    ILine ('link-'+$port) @(@($port,34),@($port,43))
    IBox ('node-'+$port) ($port-7) 43 14 12
   }
  }
  'router' {
   IBox 'case' 4 20 56 32
   ILine 'arrow-right' @(@(16,29),@(47,29),@(42,24))
   ILine 'arrow-right-head' @(@(47,29),@(42,34))
   ILine 'arrow-left' @(@(48,41),@(17,41),@(22,36))
   ILine 'arrow-left-head' @(@(17,41),@(22,46))
   ILine 'uplink-1' @(@(19,20),@(19,9))
   ILine 'uplink-2' @(@(45,20),@(45,9))
   ILine 'foot-1' @(@(14,52),@(14,57))
   ILine 'foot-2' @(@(50,52),@(50,57))
  }
  'database' {
   ILine 'left' @(@(8,15),@(8,50))
   ILine 'right' @(@(56,15),@(56,50))
   IOval 'top' 32 15 24 7
   IOval 'band-1' 32 31 24 7 0 180
   IOval 'band-2' 32 43 24 7 0 180
   IOval 'bottom' 32 50 24 7 0 180
  }
  default { throw "Pictogramme inconnu : $kind" }
 }
}



function Card($id,$x,$y,$w,$h) { Rect $id $x $y $w $h '#FFFFFF' '#000000' 0 }
function Glyph($id,$kind,$x,$y,$size=52) {
 $ratio=$size/64.0
 function GlyphLine($part,$coords) {
  $points=[System.Collections.Generic.List[object]]::new()
  foreach($point in $coords) {
   [void]$points.Add(@([int][Math]::Round($x+$point[0]*$ratio),[int][Math]::Round($y+$point[1]*$ratio)))
  }
  Arrow ($id+'-'+$part) $points.ToArray() '#000000' $false $false '' '' 2
 }
 switch($kind) {
  'folder' {
   GlyphLine 'outline' @(@(6,18),@(6,9),@(25,9),@(34,18),@(58,18),@(58,54),@(6,54),@(6,18))
   GlyphLine 'rim' @(@(6,25),@(58,25))
   GlyphLine 'files' @(@(16,35),@(45,35))
  }
  'file' {
   GlyphLine 'outline' @(@(14,6),@(38,6),@(51,19),@(51,58),@(14,58),@(14,6))
   GlyphLine 'fold' @(@(38,6),@(38,19),@(51,19))
   GlyphLine 'row-1' @(@(22,30),@(43,30))
   GlyphLine 'row-2' @(@(22,39),@(43,39))
   GlyphLine 'row-3' @(@(22,48),@(39,48))
  }
  'archive' {
   GlyphLine 'outline' @(@(14,6),@(38,6),@(51,19),@(51,58),@(14,58),@(14,6))
   GlyphLine 'fold' @(@(38,6),@(38,19),@(51,19))
   GlyphLine 'zip-left' @(@(27,17),@(27,48))
   GlyphLine 'zip-right' @(@(34,17),@(34,48))
   foreach($zy in @(21,29,37)) { GlyphLine ('zip-'+$zy) @(@(27,$zy),@(34,$zy)) }
   GlyphLine 'zip-pull' @(@(27,46),@(34,46),@(34,53),@(27,53),@(27,46))
  }
  default { throw "Type de pictogramme inconnu : $kind" }
 }
}






. (Join-Path $PSScriptRoot 'composition.ps1')
function Esc($value) { return [System.Security.SecurityElement]::Escape([string]$value) }
function Color($hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
function RoundedPath($x,$y,$w,$h,$r) {
 $path=[System.Drawing.Drawing2D.GraphicsPath]::new()
 if ($r -le 0) { $path.AddRectangle([System.Drawing.RectangleF]::new($x,$y,$w,$h)); return $path }
 $d=[single]($r*2)
 $path.AddArc([single]$x,[single]$y,$d,$d,180,90)
 $path.AddArc([single]($x+$w-$d),[single]$y,$d,$d,270,90)
 $path.AddArc([single]($x+$w-$d),[single]($y+$h-$d),$d,$d,0,90)
 $path.AddArc([single]$x,[single]($y+$h-$d),$d,$d,90,90)
 $path.CloseFigure()
 return $path
}

$document=[System.Xml.XmlDocument]::new()
$document.LoadXml('<mxfile host="app.diagrams.net" type="device"/>')
$rootFile=$document.DocumentElement
foreach ($page in $Pages) {
 $diagram=$document.CreateElement('diagram')
 $diagram.SetAttribute('id',$page.Slug); $diagram.SetAttribute('name',$page.Name)
 [void]$rootFile.AppendChild($diagram)
 $model=$document.CreateElement('mxGraphModel')
 foreach ($attribute in @{dx='2400';dy='1600';grid='1';gridSize='20';guides='1';tooltips='1';connect='1';arrows='1';fold='1';page='1';pageScale='1';pageWidth='2400';pageHeight='1600';background=$Bg}.GetEnumerator()) { $model.SetAttribute($attribute.Key,$attribute.Value) }
 [void]$diagram.AppendChild($model)
 $root=$document.CreateElement('root'); [void]$model.AppendChild($root)
 foreach($pair in @(@('0',''),@('1','0'))) {
  $base=$document.CreateElement('mxCell'); $base.SetAttribute('id',$pair[0])
  if($pair[1]) { $base.SetAttribute('parent',$pair[1]) }
  [void]$root.AppendChild($base)
 }
 $svg=[System.Text.StringBuilder]::new()
 [void]$svg.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="1600" viewBox="0 0 2400 1600" role="img" aria-labelledby="title desc">')
 [void]$svg.AppendLine(('<title id="title">'+(Esc $page.Name)+'</title><desc id="desc">Dossier technique Patroni et Odoo 14. Configuration du 3 novembre 2026, HA activée dans le dépôt.</desc>'))
 $bitmap=[System.Drawing.Bitmap]::new(4800,3200)
 $bitmap.SetResolution(192,192)
 $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
 $graphics.ScaleTransform(2,2)
 $graphics.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
 $graphics.TextRenderingHint=[System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
 $graphics.Clear((Color $Bg))
 foreach($item in $page.Items) {
  $cell=$document.CreateElement('mxCell'); $cell.SetAttribute('id',$item.Id); $cell.SetAttribute('parent','1')
  $geometry=$document.CreateElement('mxGeometry'); $geometry.SetAttribute('as','geometry')
  if($item.Kind -eq 'line') {
   $widthText=$item.Width.ToString([System.Globalization.CultureInfo]::InvariantCulture)
   $cell.SetAttribute('edge','1')
   $end=if($item.Head){'block'}else{'none'}
   $dash=if($item.Dashed){'1'}else{'0'}
   $style="edgeStyle=none;rounded=0;html=0;strokeColor=$($item.Color);strokeWidth=$widthText;endArrow=$end;endFill=1;endSize=10;dashed=$dash;dashPattern=8 6;"
   foreach($endName in @('Source','Target')) {
    $nodeId=$item.$endName
    if($nodeId) {
     $node=$page.Items | Where-Object { $_.Id -eq $nodeId } | Select-Object -First 1
     if(!$node -or $node.Kind -ne 'rect') { throw "Ancrage absent : $nodeId" }
     $point=if($endName -eq 'Source'){$item.Points[0]}else{$item.Points[$item.Points.Count-1]}
     $px=([double]$point[0]-$node.X)/$node.W; $py=([double]$point[1]-$node.Y)/$node.H
     $invariant=[System.Globalization.CultureInfo]::InvariantCulture
     $prefix=if($endName -eq 'Source'){'exit'}else{'entry'}
     $style+=$prefix+'X='+$px.ToString($invariant)+';'+$prefix+'Y='+$py.ToString($invariant)+';'+$prefix+'Dx=0;'+$prefix+'Dy=0;'+$prefix+'Perimeter=0;'
     $cell.SetAttribute($endName.ToLowerInvariant(),$nodeId)
    }
   }
   if($item.Locked){ $style+=';locked=1;selectable=0;movable=0;resizable=0;connectable=0;'; $cell.SetAttribute('connectable','0') }
   $cell.SetAttribute('style',$style); $geometry.SetAttribute('relative','1')
   for($i=0;$i -lt $item.Points.Count;$i++) {
    if($i -eq 0 -or $i -eq $item.Points.Count-1) {
     $point=$document.CreateElement('mxPoint'); $point.SetAttribute('x',[string]$item.Points[$i][0]); $point.SetAttribute('y',[string]$item.Points[$i][1])
     $point.SetAttribute('as',$(if($i -eq 0){'sourcePoint'}else{'targetPoint'})); [void]$geometry.AppendChild($point)
    }
   }
   if($item.Points.Count -gt 2) {
    $waypoints=$document.CreateElement('Array'); $waypoints.SetAttribute('as','points')
    for($i=1;$i -lt $item.Points.Count-1;$i++) {
     $point=$document.CreateElement('mxPoint'); $point.SetAttribute('x',[string]$item.Points[$i][0]); $point.SetAttribute('y',[string]$item.Points[$i][1]); [void]$waypoints.AppendChild($point)
    }
    [void]$geometry.AppendChild($waypoints)
   }
   $coords=($item.Points | ForEach-Object { [string]$_[0]+','+[string]$_[1] }) -join ' '
   $marker=''
   if($item.Head) {
    [void]$svg.AppendLine('<defs><marker id="arrow-'+$item.Id+'" markerWidth="12" markerHeight="12" refX="11" refY="6" orient="auto" markerUnits="userSpaceOnUse"><path d="M0 1 L11 6 L0 11 Z" fill="'+$item.Color+'"/></marker></defs>')
    $marker=' marker-end="url(#arrow-'+$item.Id+')"'
   }
   $dashSvg=if($item.Dashed){' stroke-dasharray="8 6"'}else{''}
   [void]$svg.AppendLine('<polyline points="'+$coords+'" fill="none" stroke="'+$item.Color+'" stroke-width="'+$widthText+'" stroke-linejoin="round"'+$dashSvg+$marker+'/>')
   $pen=[System.Drawing.Pen]::new((Color $item.Color),[single]$item.Width)
   $pen.LineJoin=[System.Drawing.Drawing2D.LineJoin]::Round
   if($item.Dashed){ $pen.DashPattern=[single[]]@((8/$item.Width),(6/$item.Width)) }
   $drawPoints=[System.Drawing.PointF[]]@($item.Points | ForEach-Object { [System.Drawing.PointF]::new([single]$_[0],[single]$_[1]) })
   $graphics.DrawLines($pen,$drawPoints)
   if($item.Head) {
    $last=$item.Points[$item.Points.Count-1]; $prev=$item.Points[$item.Points.Count-2]
    $dx=$last[0]-$prev[0]; $dy=$last[1]-$prev[1]; $length=[Math]::Sqrt($dx*$dx+$dy*$dy)
    if($length -gt 0) {
     $ux=$dx/$length; $uy=$dy/$length
     $triangle=[System.Drawing.PointF[]]@(
      [System.Drawing.PointF]::new($last[0],$last[1]),
      [System.Drawing.PointF]::new(($last[0]-11*$ux-5*$uy),($last[1]-11*$uy+5*$ux)),
      [System.Drawing.PointF]::new(($last[0]-11*$ux+5*$uy),($last[1]-11*$uy-5*$ux))
     )
     $brush=[System.Drawing.SolidBrush]::new((Color $item.Color)); $graphics.FillPolygon($brush,$triangle); $brush.Dispose()
    }
   }
   $pen.Dispose()
  } else {
   $cell.SetAttribute('vertex','1')
   foreach($key in @('X','Y','W','H')) { $attr=@{X='x';Y='y';W='width';H='height'}[$key]; $geometry.SetAttribute($attr,[string]$item.$key) }
   if($item.Kind -eq 'rect') {
    $rounded=if($item.Radius -gt 0){1}else{0}
    $cell.SetAttribute('style',"rounded=$rounded;arcSize=$($item.Radius);absoluteArcSize=1;whiteSpace=wrap;html=0;fillColor=$($item.Fill);strokeColor=$($item.Stroke);strokeWidth=1.5;")
    if($item.Id -in @('background','header')) { $cell.SetAttribute('style',$cell.GetAttribute('style')+'locked=1;') }
    [void]$svg.AppendLine('<rect x="'+$item.X+'" y="'+$item.Y+'" width="'+$item.W+'" height="'+$item.H+'" rx="'+$item.Radius+'" fill="'+$item.Fill+'" stroke="'+$item.Stroke+'" stroke-width="1.5"/>')
    $shape=RoundedPath $item.X $item.Y $item.W $item.H $item.Radius
    if($item.Fill -ne 'none') { $brush=[System.Drawing.SolidBrush]::new((Color $item.Fill)); $graphics.FillPath($brush,$shape); $brush.Dispose() }
    if($item.Stroke -ne 'none') { $pen=[System.Drawing.Pen]::new((Color $item.Stroke),[single]1.5); $graphics.DrawPath($pen,$shape); $pen.Dispose() }
    $shape.Dispose()
   } else {
    $weight=if($item.Bold){1}else{0}
    $cell.SetAttribute('value',$item.Text)
    $cell.SetAttribute('style',"text;html=0;whiteSpace=wrap;overflow=hidden;align=$($item.Align);verticalAlign=middle;spacing=0;fontFamily=Segoe UI;fontSize=$($item.Size);fontStyle=$weight;fontColor=$($item.Color);strokeColor=none;fillColor=#FFFFFF;labelBackgroundColor=#FFFFFF;")
    $rows=$item.Text.Split([char]10); $lineHeight=$item.Size*1.35
    $anchor=if($item.Align -eq 'center'){'middle'}elseif($item.Align -eq 'right'){'end'}else{'start'}
    $tx=if($item.Align -eq 'center'){$item.X+$item.W/2}elseif($item.Align -eq 'right'){$item.X+$item.W}else{$item.X}
    $ty=$item.Y+($item.H-$rows.Count*$lineHeight)/2+$item.Size
    $fontWeight=if($item.Bold){'600'}else{'400'}
    [void]$svg.AppendLine('<rect x="'+$item.X+'" y="'+$item.Y+'" width="'+$item.W+'" height="'+$item.H+'" fill="#FFFFFF" stroke="none"/>')
    [void]$svg.AppendLine('<text fill="'+$item.Color+'" font-family="Segoe UI, Arial, sans-serif" font-size="'+$item.Size+'" font-weight="'+$fontWeight+'" text-anchor="'+$anchor+'">')
    foreach($row in $rows) {
     [void]$svg.AppendLine('<tspan x="'+$tx+'" y="'+$ty.ToString([System.Globalization.CultureInfo]::InvariantCulture)+'">'+(Esc $row)+'</tspan>')
     $ty+=$lineHeight
    }
    [void]$svg.AppendLine('</text>')
    $fontStyle=if($item.Bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
    $font=[System.Drawing.Font]::new('Segoe UI',[single]$item.Size,$fontStyle,[System.Drawing.GraphicsUnit]::Pixel)
    $brush=[System.Drawing.SolidBrush]::new((Color $item.Color))
    $format=[System.Drawing.StringFormat]::new()
    $format.Alignment=if($item.Align -eq 'center'){[System.Drawing.StringAlignment]::Center}elseif($item.Align -eq 'right'){[System.Drawing.StringAlignment]::Far}else{[System.Drawing.StringAlignment]::Near}
    $format.LineAlignment=[System.Drawing.StringAlignment]::Center
    $format.FormatFlags=[System.Drawing.StringFormatFlags]::NoWrap
    foreach($row in $rows) {
     $measure=$graphics.MeasureString($row,$font,10000,$format)
     if($measure.Width -gt $item.W+2){ [void]$Warnings.Add("$($page.Slug)/$($item.Id) : largeur texte $([int]$measure.Width) > $($item.W)") }
    }
    if($rows.Count*$font.GetHeight($graphics) -gt $item.H+2) { [void]$Warnings.Add("$($page.Slug)/$($item.Id) : hauteur texte insuffisante") }
    $textBackdrop=[System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $graphics.FillRectangle($textBackdrop,[System.Drawing.RectangleF]::new($item.X,$item.Y,$item.W,$item.H))
    $textBackdrop.Dispose()
    $graphics.DrawString($item.Text,$font,$brush,[System.Drawing.RectangleF]::new($item.X,$item.Y,$item.W,$item.H),$format)
    $format.Dispose(); $brush.Dispose(); $font.Dispose()
   }
  }
  [void]$cell.AppendChild($geometry); [void]$root.AppendChild($cell)
 }
 [void]$svg.AppendLine('</svg>')
 $svgPath=Join-Path $OutputDirectory ($page.Slug+'.svg')
 [System.IO.File]::WriteAllText($svgPath,$svg.ToString(),[System.Text.UTF8Encoding]::new($false))
 $bitmap.Save((Join-Path $OutputDirectory ($page.Slug+'.png')),[System.Drawing.Imaging.ImageFormat]::Png)
 $graphics.Dispose(); $bitmap.Dispose()
 $parsedSvg=[xml][System.IO.File]::ReadAllText($svgPath)
 $ids=@($page.Items | ForEach-Object {$_.Id})
 if(@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw "Identifiants dupliqués : $($page.Slug)" }
 foreach($item in $page.Items | Where-Object {$_.Kind -ne 'line'}) {
  if($item.X -lt 0 -or $item.Y -lt 0 -or $item.X+$item.W -gt 2400 -or $item.Y+$item.H -gt 1600) { throw "Élément hors page : $($page.Slug)/$($item.Id)" }
 }

 $one=[System.Xml.XmlDocument]::new()
 $one.LoadXml('<mxfile host="app.diagrams.net" type="device"/>')
 [void]$one.DocumentElement.AppendChild($one.ImportNode($diagram,$true))
 $one.Save((Join-Path $OutputDirectory ($page.Slug+'.drawio')))
}

. (Join-Path $PSScriptRoot 'finalisation.ps1')
