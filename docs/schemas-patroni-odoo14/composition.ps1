
# Composition commune : toutes les pages sont en 2400 x 1600.
$layoutBitmap=[System.Drawing.Bitmap]::new(1,1)
$layoutGraphics=[System.Drawing.Graphics]::FromImage($layoutBitmap)
function PText($id,$value,$x,$y,$w,$h,$size=24,$bold=$false,$align='left') {
 $style=if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
 $paragraphs=([string]$value).Replace('|',[string][char]10).Split([char]10)
 for($candidate=[double]$size;$candidate -ge [Math]::Min(18,$size);$candidate-=0.5) {
  $font=[System.Drawing.Font]::new('Segoe UI',[single]$candidate,$style,[System.Drawing.GraphicsUnit]::Pixel)
  $rows=[System.Collections.Generic.List[string]]::new()
  $tooWide=$false
  foreach($paragraph in $paragraphs) {
   $line=''
   foreach($word in ($paragraph -split ' ')) {
    $next=if($line){$line+' '+$word}else{$word}
    if($layoutGraphics.MeasureString($next,$font).Width -gt $w-4 -and $line) { [void]$rows.Add($line);$line=$word } else {$line=$next}
   }
   [void]$rows.Add($line)
   if($layoutGraphics.MeasureString($line,$font).Width -gt $w-2){$tooWide=$true}
  }
  $font.Dispose()
  if(!$tooWide -and $rows.Count*$candidate*1.35 -le $h) {break}
 }
 if($candidate -lt [Math]::Min(18,$size)){throw "Texte impossible a placer : $($script:Page.Slug)/$id"}
 Txt $id ($rows -join [string][char]10) $x $y $w $h $candidate '#000000' $bold $align
}
function PCard($c) {
 $id=$c[1];$x=[double]$c[2];$y=[double]$c[3];$w=[double]$c[4];$h=[double]$c[5]
 Card $id $x $y $w $h
 $icon=$c[8];$tx=$x+26;$tw=$w-52
 if($icon) {
  if($icon -in @('folder','file','archive')) {Glyph ($id+'-icon') $icon ($x+22) ($y+20) 48}
  else {Icon ($id+'-icon') $icon ($x+22) ($y+20) 48}
  $tx=$x+90;$tw=$w-116
 }
 $titleHeight=if($h -le 140){44}else{58}
 PText ($id+'-title') $c[6] $tx ($y+14) $tw $titleHeight 28 $true
 $bodyY=if($h -le 140){$y+60}else{$y+78}
 $bodyHeight=$y+$h-10-$bodyY
 if($c[7]) {PText ($id+'-body') $c[7] ($x+26) $bodyY ($w-52) $bodyHeight 24}
}
$records=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'schemas.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pageNumber=0
foreach($record in $records) {
 $pageNumber++
 $script:Page=[pscustomobject]@{Slug=$record.slug;Name=('{0:00} - {1}' -f $pageNumber,$record.title);Items=[System.Collections.Generic.List[object]]::new()}
 [void]$script:Pages.Add($script:Page)
 Rect 'background' 0 0 2400 1600 '#FFFFFF' 'none' 0
 for($gx=20;$gx -lt 2400;$gx+=20) {
  $weight=if($gx%100 -eq 0){0.25}else{0.12}
  Arrow ('grid-v-'+$gx) @(@($gx,210),@($gx,1490)) '#000000' $false $false '' '' $weight $true
 }
 for($gy=220;$gy -lt 1490;$gy+=20) {
  $weight=if($gy%100 -eq 0){0.25}else{0.12}
  Arrow ('grid-h-'+$gy) @(@(0,$gy),@(2400,$gy)) '#000000' $false $false '' '' $weight $true
 }
 Rect 'header' 0 0 2400 210 '#FFFFFF' 'none' 0
 PText 'category' ('DOSSIER TECHNIQUE / '+('{0:00}' -f $pageNumber)+' / ODOO 14 + PATRONI') 60 24 1850 35 20 $true
 PText 'page-title' $record.title 60 72 1800 70 44 $true
 Card 'tag' 1940 72 400 62
 PText 'tag-text' $record.tag 1950 80 380 46 24 $true 'center'
 PText 'subtitle' $record.subtitle 60 155 2280 40 24
 Arrow 'header-rule' @(@(0,210),@(2400,210)) '#000000' $false $false '' '' 1.5
 foreach($c in $record.commands) {
  switch($c[0]) {
   'box' {
    Card $c[1] $c[2] $c[3] $c[4] $c[5]
    PText ($c[1]+'-heading') $c[6] ($c[2]+26) ($c[3]+18) ($c[4]-52) 60 28 $true
   }
   'card' {PCard $c}
   'text' {PText $c[1] $c[2] $c[3] $c[4] $c[5] $c[6] $c[7] $c[8] $c[9]}
   'edge' {Arrow $c[1] $c[2] '#000000' $c[3] $c[7] $c[4] $c[5] $c[6]}
   default {throw "Commande de dessin inconnue : $($c[0])"}
  }
 }
 Arrow 'footer-rule' @(@(60,1500),@(2340,1500)) '#000000' $false $false '' '' 1
 Arrow 'legend-data' @(@(70,1524),@(140,1524)) '#000000' $false $true '' '' 3
 PText 'legend-data-text' 'Flux applicatif / SQL / WAL / stockage' 160 1508 730 34 18
 Arrow 'legend-control' @(@(980,1524),@(1050,1524)) '#000000' $true $true
 PText 'legend-control-text' 'Pilotage / sondes / enchaînement des étapes' 1070 1508 1030 34 18
 PText 'sources' ('3 novembre 2026 · HA=true · Sources : '+$record.sources) 60 1555 2080 30 16
 PText 'page-number' ('{0:00} / {1:00}' -f $pageNumber,$records.Count) 2170 1555 170 30 18 $true 'right'
}
$layoutGraphics.Dispose();$layoutBitmap.Dispose()
