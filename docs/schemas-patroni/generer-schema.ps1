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
function New-Page($slug,$name,$index,$category,$title,$subtitle,$tag) {
 $script:Page=[pscustomobject]@{Slug=$slug;Name=$name;Items=[System.Collections.Generic.List[object]]::new()}
 [void]$script:Pages.Add($script:Page)
 Rect 'background' 0 0 1600 1000 $Bg 'none' 0
 Rect 'header' 0 0 1600 138 $Navy 'none' 0
 Txt 'category' ($index+' / '+$category) 60 21 1200 24 13 '#000000' $true
 Txt 'title' $title 60 53 1240 45 32 '#FFFFFF' $true
 Txt 'subtitle' $subtitle 60 101 1260 25 16 '#000000'
 Rect 'tag' 1340 48 200 46 $Blue 'none' 23
 Txt 'tag-text' $tag 1350 53 180 34 17 '#FFFFFF' $true 'center'
 Arrow 'footer-rule' @(@(60,948),@(1540,948)) $Border $false $false
 Txt 'footer' 'Configuration du dépôt · 25 octobre 2026 · État des serveurs non audité' 60 960 1200 25 13 $Muted
 Txt 'page-number' ($index+' / 01') 1400 960 140 25 14 $Muted $true 'right'
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
function New-GridPage($slug,$name,$index,$category,$title,$subtitle,$tag) {
 New-Page $slug $name $index $category $title $subtitle $tag
 $previous=@($script:Page.Items)
 $script:Page.Items=[System.Collections.Generic.List[object]]::new()
 Rect 'background' 0 0 1600 1000 '#FFFFFF' 'none' 0
 for($gx=20;$gx -lt 1600;$gx+=20) {
  $lineWidth=if($gx%100 -eq 0){0.35}else{0.18}
  Arrow ('grid-v-'+$gx) @(@($gx,0),@($gx,1000)) '#000000' $false $false '' '' $lineWidth $true
 }
 for($gy=20;$gy -lt 1000;$gy+=20) {
  $lineWidth=if($gy%100 -eq 0){0.35}else{0.18}
  Arrow ('grid-h-'+$gy) @(@(0,$gy),@(1600,$gy)) '#000000' $false $false '' '' $lineWidth $true
 }
 foreach($item in $previous) {
  if($item.Id -eq 'background') { continue }
  switch($item.Kind) {
   'rect' { $item.Fill='#FFFFFF'; $item.Stroke='#000000'; $item.Radius=0; if($item.Id -eq 'header'){$item.Stroke='none'} }
   'text' { $item.Color='#000000' }
   'line' { $item.Color='#000000' }
  }
  [void]$script:Page.Items.Add($item)
 }
 Arrow 'header-rule' @(@(0,138),@(1600,138)) '#000000' $false $false '' '' 1
 Rect 'legend-backdrop' 945 142 595 24 '#FFFFFF' 'none' 0
 Arrow 'legend-access' @(@(960,154),@(1000,154))
 Txt 'legend-access-label' 'SQL / WAL' 1013 143 205 23 13
 Arrow 'legend-copy' @(@(1250,154),@(1290,154)) '#000000' $true
 Txt 'legend-copy-label' 'Pilotage / sondes' 1303 143 210 23 13
}
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





New-GridPage 'orchestration-patroni-haproxy-postgresql' 'Orchestration Patroni HAProxy PostgreSQL' '01' 'ORCHESTRATION POSTGRESQL' 'Patroni orchestre, HAProxy oriente le SQL' 'Un agent Patroni par PostgreSQL ; etcd coordonne le leader ; HAProxy suit le rôle publié.' 'OPTION HA'
Card 'status' 60 175 1480 60
Txt 'status-label' 'MODE HA PRÉVU · pg_ha_enabled = false dans le dépôt · schéma explicatif, sans test sur les serveurs' 85 190 1420 32 21 '#000000' $true

Card 'clients' 60 280 340 110
Icon 'icon-clients' 'browser' 80 299 52
Txt 'clients-title' 'Odoo / libpq' 150 290 230 32 23 '#000000' $true
Txt 'clients-detail' 'Connexions SQL en TLS' 80 351 300 27 18

Card 'haproxy' 550 280 450 110
Icon 'icon-haproxy' 'network' 570 290 44
Txt 'haproxy-title' 'HAProxy choisi · TCP/5000' 635 290 345 31 22 '#000000' $true
Txt 'haproxy-choice' 'libpq choisit une des trois instances' 575 338 405 25 17
Txt 'haproxy-addresses' '.33.161 / .33.162 / .33.163 :5000' 575 368 405 19 14

Card 'routing-note' 1140 280 400 110
Txt 'routing-note-title' 'LE RÔLE DÉTERMINE LA CIBLE SQL' 1160 292 360 26 15 '#000000' $true
Txt 'routing-note-body' 'HAProxy envoie les connexions|au primaire indiqué par Patroni.' 1160 333 360 48 17

Card 'primary' 550 490 450 120
Icon 'icon-primary' 'database' 570 507 50
Txt 'primary-title' 'PostgreSQL primaire' 635 504 345 32 23 '#000000' $true
Txt 'primary-detail' 'Exemple : odoodb1 · .33.161:5432' 575 565 405 28 19

Card 'replicas' 1140 490 400 120
Icon 'icon-replicas' 'database' 1160 507 50
Txt 'replicas-title' 'Répliques PostgreSQL' 1230 504 290 32 21 '#000000' $true
Txt 'replicas-detail' 'odoodb2 : .33.162|odoodb3 : .33.163' 1160 553 360 45 17

Arrow 'clients-to-haproxy' @(@(400,335),@(550,335)) '#000000' $false $true 'clients' 'haproxy' 3
Txt 'client-sql-label' 'SQL / TLS' 412 295 126 26 15 '#000000' $true 'center'
Arrow 'haproxy-to-primary' @(@(775,390),@(775,490)) '#000000' $false $true 'haproxy' 'primary' 3
Txt 'primary-sql-label' 'SQL vers TCP/5432' 798 427 290 29 19 '#000000' $true
Arrow 'wal-direct' @(@(1000,550),@(1140,550)) '#000000' $false $true 'primary' 'replicas' 1.8
Txt 'wal-label' 'WAL directs' 1008 509 124 25 14 '#000000' $true 'center'

Card 'health-note' 60 450 340 190
Txt 'health-title' 'SONDES DE CHAQUE HAPROXY' 80 463 300 27 15 '#000000' $true
Txt 'health-details' 'GET /primary sur HTTP/8008|200 : primaire avec verrou|503 : réplique pour ce test|Une sonde sur chaque Patroni' 80 509 300 103 17

Card 'patroni' 550 725 450 115
Icon 'icon-patroni' 'server' 570 735 44
Txt 'patroni-title' 'Agents Patroni ×3' 635 737 345 32 24 '#000000' $true
Txt 'patroni-detail' 'Un agent par PostgreSQL|Démarre, arrête et promeut localement' 575 785 405 48 17

Card 'etcd' 60 725 340 115
Icon 'icon-etcd' 'network' 80 735 44
Txt 'etcd-title' 'etcd · 3 membres' 145 737 235 32 22 '#000000' $true
Txt 'etcd-detail' 'Verrou + configuration|Quorum 2/3 · pairs :2380' 80 785 300 48 17

Arrow 'haproxy-health' @(@(550,360),@(470,360),@(470,785),@(550,785)) '#000000' $true $true 'haproxy' 'patroni'
Txt 'health-path-label' 'Sondes des|3 agents' 408 651 128 43 15 '#000000' $true 'center'
Arrow 'patroni-primary-control' @(@(775,725),@(775,610)) '#000000' $true $true 'patroni' 'primary'
Txt 'primary-control-label' 'Pilote PostgreSQL local' 798 652 300 28 18 '#000000' $true
Arrow 'patroni-replica-control' @(@(1000,785),@(1340,785),@(1340,610)) '#000000' $true $true 'patroni' 'replicas'
Txt 'replica-control-label' 'Chaque Patroni pilote uniquement|son PostgreSQL local' 1145 652 390 49 17 '#000000' $true 'center'
Arrow 'patroni-to-etcd' @(@(775,840),@(775,870),@(230,870),@(230,840)) '#000000' $true $true 'patroni' 'etcd'
Txt 'etcd-coordination-label' 'Coordination HTTPS :2379' 370 854 300 27 16 '#000000' $true 'center'

Card 'roles-summary' 60 910 1480 26
Txt 'roles-summary-text' 'Patroni : pilotage des rôles · HAProxy : routage TCP · PostgreSQL : données et WAL · etcd : coordination du leader' 80 912 1440 22 16 '#000000' $true

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
 foreach ($attribute in @{dx='1600';dy='1000';grid='1';gridSize='20';guides='1';tooltips='1';connect='1';arrows='1';fold='1';page='1';pageScale='1';pageWidth='1600';pageHeight='1000';background=$Bg}.GetEnumerator()) { $model.SetAttribute($attribute.Key,$attribute.Value) }
 [void]$diagram.AppendChild($model)
 $root=$document.CreateElement('root'); [void]$model.AppendChild($root)
 foreach($pair in @(@('0',''),@('1','0'))) {
  $base=$document.CreateElement('mxCell'); $base.SetAttribute('id',$pair[0])
  if($pair[1]) { $base.SetAttribute('parent',$pair[1]) }
  [void]$root.AppendChild($base)
 }
 $svg=[System.Text.StringBuilder]::new()
 [void]$svg.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000" role="img" aria-labelledby="title desc">')
 [void]$svg.AppendLine(('<title id="title">'+(Esc $page.Name)+'</title><desc id="desc">Orchestration Patroni, HAProxy et PostgreSQL. Configuration du dépôt du 25 octobre 2026, serveurs non audités.</desc>'))
 $bitmap=[System.Drawing.Bitmap]::new(3200,2000)
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
  if($item.X -lt 0 -or $item.Y -lt 0 -or $item.X+$item.W -gt 1600 -or $item.Y+$item.H -gt 1000) { throw "Élément hors page : $($page.Slug)/$($item.Id)" }
 }
}
$drawio=Join-Path $OutputDirectory 'orchestration-patroni-haproxy-postgresql.drawio'
$document.Save($drawio)
$parsed=[xml][System.IO.File]::ReadAllText($drawio)
if($parsed.SelectNodes('//diagram').Count -ne 1) { throw 'Le document doit contenir une page.' }
if($Warnings.Count -gt 0) { throw ('Débordements typographiques : '+($Warnings -join ' ; ')) }




$readme='# Patroni dans l''orchestration de PostgreSQL et HAProxy

[Ouvrir le schéma draw.io modifiable](orchestration-patroni-haproxy-postgresql.drawio) · [PNG haute résolution](orchestration-patroni-haproxy-postgresql.png) · [SVG vectoriel](orchestration-patroni-haproxy-postgresql.svg)

![Orchestration PostgreSQL](orchestration-patroni-haproxy-postgresql.png)

Schéma explicatif du mode HA prévu dans le dépôt au **25 octobre 2026**. Le mode reste désactivé dans la configuration : pg_ha_enabled=false. Aucun service ni serveur n''a été modifié ou interrogé pour produire ce dessin.

Le style reprend les autres schémas : noir et blanc, icônes vectorielles, grille visible de 20 unités. Le dessin est une vue logique des rôles : le groupe des agents Patroni rassemble trois processus indépendants, un par nœud. Le HAProxy représenté est celui choisi parmi les trois instances, pas un répartiteur central unique.

## Comment lire les flèches

- **Trait plein épais :** les connexions SQL vont d''Odoo vers le HAProxy choisi sur 5000, puis vers le PostgreSQL primaire sur 5432. HAProxy conserve le TLS de bout en bout.
- **Trait plein fin, marqué WAL :** PostgreSQL réplique directement ses journaux vers ses deux répliques. Les WAL ne traversent pas les agents Patroni.
- **Pointillés, de HAProxy vers Patroni :** les sondes HTTP GET /primary sur 8008 ciblent les trois agents. 200 signifie PostgreSQL primaire avec verrou du leader ; une réplique saine répond 503 à ce contrôle. [API officielle Patroni](https://patroni.readthedocs.io/en/latest/rest_api.html)
- **Pointillés, de Patroni vers PostgreSQL :** chaque agent démarre, arrête, configure et promeut son PostgreSQL local. Aucun port réseau de pilotage local n''est inventé ; 8008 est l''API REST de Patroni.
- **Pointillés, de Patroni vers etcd :** les agents consultent le registre et acquièrent ou renouvellent le verrou du leader via HTTPS/2379. Les trois membres etcd échangent sur 2380 et exigent une majorité de deux.

## Qui fait quoi ?

| Composant | Rôle |
| --- | --- |
| PostgreSQL | Exécute les requêtes, conserve les données et réplique les WAL |
| Patroni | Supervise le PostgreSQL local et coordonne les changements de rôle à l''aide du verrou etcd |
| etcd | Conserve le verrou et la configuration du cluster ; son quorum concerne le consensus, pas les acquittements WAL |
| HAProxy | Observe le rôle publié par Patroni et route le SQL vers le primaire |
| libpq / Odoo | Essaie les trois endpoints HAProxy et ouvre une connexion au service disponible |

## Lors d''une panne

Le HAProxy retire la cible devenue indisponible et coupe les sessions qui lui étaient attachées. Les agents Patroni restants peuvent promouvoir une réserve éligible si le quorum etcd et les conditions de retard le permettent. Le HAProxy voit alors le nouveau primaire via son API Patroni ; les clients doivent ouvrir de nouvelles connexions SQL. Les transactions en cours ne sont pas transférées.

Le placement odoodb1 primaire et odoodb2/odoodb3 répliques est un exemple. La réplication reste asynchrone ; la présence d''un quorum etcd ne garantit pas zéro perte de transactions. Le projet désactive le watchdog matériel dans les LXC. Les délais réels et le scénario de panne restent à tester.

## Sources du projet

- [État HA et endpoints](../../group_vars/all/vars.yml).
- [Configuration HAProxy](../../roles/ansi_postgresql_ha/pg_ha/templates/haproxy.cfg.j2).
- [Configuration Patroni](../../roles/ansi_postgresql_ha/pg_ha/templates/patroni.yml.j2).
- [Paramètres etcd et Patroni](../../roles/ansi_postgresql_ha/pg_ha/defaults/main.yml).
- [Documentation PostgreSQL HA du projet](../POSTGRESQL-PATRONI.md).
- [Autres vues d''architecture et de bascule](../schemas-architecture-ha/README.md).

## Régénération

Depuis PowerShell sous Windows : .\generer-schema.ps1

Le générateur est autonome et utilise XML, SVG et System.Drawing. Il produit le document draw.io, le SVG et le PNG 3200 × 2000. Les retouches faites directement dans draw.io ne sont pas réimportées dans ce script.
'
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.md'),$readme,[System.Text.UTF8Encoding]::new($false))
Write-Output 'Validation : 1 page draw.io, SVG et PNG 3200 x 2000 ; textes sans débordement.'
Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name,Length
