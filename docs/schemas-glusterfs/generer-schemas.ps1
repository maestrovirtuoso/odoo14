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
 Txt 'footer' 'Configuration du dépôt · 18 octobre 2026 · État des serveurs non audité' 60 960 1200 25 13 $Muted
 Txt 'page-number' ($index+' / 03') 1400 960 140 25 14 $Muted $true 'right'
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
 Txt 'legend-access-label' 'Montage / accès' 1013 143 205 23 13
 Arrow 'legend-copy' @(@(1250,154),@(1290,154)) '#000000' $true
 Txt 'legend-copy-label' 'Copie de sauvegarde' 1303 143 210 23 13
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

New-GridPage '01-volume-partage-trois-odoo' '01 - Volume partagé entre les trois Odoo' '01' 'STOCKAGE PARTAGÉ' 'Un volume commun aux trois Odoo' 'Le montage GlusterFS est réalisé sur les hôtes, puis partagé avec les conteneurs LXC.' 'GLUSTERFS / sre'
Card 'scope' 60 200 420 145
Txt 'scope-title' 'PÉRIMÈTRE DU PROJET' 82 213 376 28 14 '#000000' $true
Txt 'scope-body' 'Volume GlusterFS déjà existant.|Le projet configure ses clients|et son partage avec les LXC.' 82 257 376 70 17

Card 'volume' 530 190 540 160
Icon 'icon-volume' 'server' 550 217 66
Txt 'volume-title' 'VOLUME GLUSTERFS EXTERNE · sre' 635 203 405 29 16 '#000000' $true
Txt 'volume-source' '192.168.36.8:/sre' 635 242 405 39 28 '#000000' $true
Txt 'volume-description' 'Description du volume récupérée à .36.8|Briques hébergées hors du projet' 635 293 405 46 16

Card 'network-scope' 1120 200 420 145
Txt 'network-scope-title' 'ACCÈS AUX SERVEURS DE BRIQUES' 1142 213 376 28 14 '#000000' $true
Txt 'network-scope-body' 'Après lecture de la description,|chaque hôte contacte directement|les serveurs du volume.' 1142 257 376 70 17

for($i=1;$i -le 3;$i++) {
 $left=60+($i-1)*530
 $center=$left+210
 Card ('host-'+$i) $left 455 420 280
 Icon ('icon-host-'+$i) 'server' ($left+25) 471 48
 Txt ('host-title-'+$i) ("HÔTE · 192.168.36.2"+$i) ($left+90) 471 305 31 21 '#000000' $true
 Card ('mount-'+$i) ($left+25) 520 370 75
 Glyph ('icon-mount-'+$i) 'folder' ($left+40) 535 42
 Txt ('mount-path-'+$i) '/mnt/odoo' ($left+100) 527 280 33 26 '#000000' $true
 Txt ('mount-type-'+$i) 'Client FUSE · fuse.glusterfs' ($left+100) 565 280 23 14
 Card ('lxc-'+$i) ($left+25) 625 370 90
 Icon ('icon-lxc-'+$i) 'container' ($left+40) 638 44
 Txt ('lxc-name-'+$i) ('odoo'+$i+' · 192.168.36.16'+$i) ($left+100) 634 280 27 18 '#000000' $true
 Txt ('lxc-path-'+$i) '/var/lib/odoo' ($left+100) 672 280 29 23 '#000000' $true
 Arrow ('mount-to-lxc-'+$i) @(@($center,595),@($center,625)) '#000000' $false $true ('mount-'+$i) ('lxc-'+$i)
 Txt ('bind-label-'+$i) 'Bind LXC' ($center+20) 597 155 23 13
 if($i -eq 2) {
  Arrow ('volume-to-host-'+$i) @(@(800,350),@($center,455)) '#000000' $false $true 'volume' ('host-'+$i)
 } else {
  Arrow ('volume-to-host-'+$i) @(@(800,350),@(800,400),@($center,400),@($center,455)) '#000000' $false $true 'volume' ('host-'+$i)
 }
 Txt ('client-label-'+$i) 'Montage GlusterFS' ($center-115) 416 230 25 15 '#000000' $true 'center'
}
Card 'shared-note' 60 790 1480 120
Txt 'shared-note-title' 'UN STOCKAGE LOGIQUE PARTAGÉ' 85 803 1420 25 14 '#000000' $true
Txt 'shared-note-main' 'Une pièce jointe écrite par odoo1 devient accessible à odoo2 et odoo3.' 85 839 1420 32 23 '#000000' $true
Txt 'shared-note-detail' "Le groupe gluster_bricks désigne les hôtes clients. Les hôtes PostgreSQL ne reçoivent pas ce montage." 85 878 1420 24 17

New-GridPage '02-montage-hote-et-bind-lxc' '02 - Montage hôte et bind LXC' '02' 'DÉTAIL DU MONTAGE' "Du volume GlusterFS au data_dir d'Odoo" "Le bind LXC présente le montage de l'hôte dans le conteneur, avec les mêmes fichiers." 'MONTAGE / LXC'
Card 'host' 60 200 850 470
Icon 'icon-host' 'server' 90 220 60
Txt 'host-title' 'HÔTE · 192.168.36.21' 170 219 700 34 24 '#000000' $true
Txt 'host-description' "Le client GlusterFS s'exécute sur cet hôte." 170 261 700 27 17

Card 'gluster-client' 90 325 330 135
Icon 'icon-client' 'server' 110 338 50
Txt 'client-title' 'CLIENT GLUSTERFS' 175 336 220 27 15 '#000000' $true
Txt 'client-source' '192.168.36.8:/sre' 110 403 290 33 23 '#000000' $true

Card 'host-mount' 510 325 350 135
Glyph 'icon-mount' 'folder' 530 338 52
Txt 'mount-title' 'POINT DE MONTAGE' 595 337 245 27 15 '#000000' $true
Txt 'host-path' '/mnt/odoo' 530 398 310 42 29 '#000000' $true

Card 'configuration' 90 500 770 135
Glyph 'icon-configuration' 'file' 110 516 48
Txt 'configuration-title' "CONFIGURATION SUR L'HÔTE" 175 511 660 28 15 '#000000' $true
Txt 'configuration-paths' '/etc/fstab : montage GlusterFS persistant|/var/lib/lxc/devodoo14/config : bind LXC' 110 561 725 56 18

Card 'container' 1010 200 530 470
Icon 'icon-container' 'container' 1040 218 60
Txt 'container-title' 'ODOO1 · devodoo14' 1120 219 390 34 24 '#000000' $true
Txt 'container-address' 'Conteneur : 192.168.36.161' 1120 261 390 27 18

Card 'data-dir' 1035 325 480 135
Glyph 'icon-data-dir' 'folder' 1055 338 52
Txt 'data-dir-title' "DATA_DIR D'ODOO" 1120 337 365 27 15 '#000000' $true
Txt 'container-path' '/var/lib/odoo' 1055 398 435 42 29 '#000000' $true

Card 'filestore' 1035 520 225 115
Glyph 'icon-filestore' 'folder' 1047 534 34
Txt 'filestore-title' 'FILESTORE' 1090 532 155 23 13 '#000000' $true
Txt 'filestore-path' 'filestore/prod/' 1050 568 195 26 18 '#000000' $true
Txt 'filestore-caption' 'Documents et images' 1050 603 195 23 14
Card 'sessions' 1290 520 225 115
Glyph 'icon-sessions' 'folder' 1302 534 34
Txt 'sessions-title' 'SESSIONS' 1345 532 155 23 13 '#000000' $true
Txt 'sessions-path' 'sessions/' 1305 568 195 26 18 '#000000' $true
Txt 'sessions-caption' 'Sessions partagées' 1305 603 195 23 14

Arrow 'client-to-mount' @(@(420,392),@(510,392)) '#000000' $false $true 'gluster-client' 'host-mount'
Txt 'mount-arrow-label' 'Montage' 422 346 86 27 13 '#000000' $false 'center'
Arrow 'mount-to-container' @(@(860,392),@(1035,392)) '#000000' $false $true 'host-mount' 'data-dir'
Txt 'bind-arrow-label' 'Bind LXC' 875 345 130 27 15 '#000000' $true 'center'
Arrow 'data-dir-to-filestore' @(@(1275,460),@(1275,493),@(1147,493),@(1147,520)) '#000000' $false $true 'data-dir' 'filestore'
Arrow 'data-dir-to-sessions' @(@(1275,460),@(1275,493),@(1402,493),@(1402,520)) '#000000' $false $true 'data-dir' 'sessions'

Card 'lxc-entry' 60 715 1480 90
Txt 'lxc-entry-title' 'DIRECTIVE LXC ÉCRITE PAR ANSIBLE' 85 726 1420 25 14 '#000000' $true
Txt 'lxc-entry-value' 'lxc.mount.entry = /mnt/odoo var/lib/odoo none bind,create=dir 0 0' 85 760 1420 33 23 '#000000' $true

Card 'guard-1' 60 835 470 80
Txt 'guard-1-title' '01 / MONTAGE APRÈS LE RÉSEAU' 80 843 430 24 14 '#000000' $true
Txt 'guard-1-body' 'fstab : defaults,_netdev' 80 879 430 25 18
Card 'guard-2' 565 835 470 80
Txt 'guard-2-title' '02 / CONTRÔLE DU VOLUME' 585 843 430 24 14 '#000000' $true
Txt 'guard-2-body' 'findmnt : type fuse.glusterfs' 585 879 430 25 18
Card 'guard-3' 1070 835 470 80
Txt 'guard-3-title' '03 / APPLICATION DU BIND' 1090 843 430 24 14 '#000000' $true
Txt 'guard-3-body' 'Redémarrage LXC si la directive change.' 1090 879 430 25 17

New-GridPage '03-glusterfs-et-sauvegarde' '03 - GlusterFS et sauvegarde Odoo' '03' 'SAUVEGARDE ODOO' 'Sauvegarder la base et les fichiers' "L'hôte 192.168.36.21 lit PostgreSQL et le volume partagé, puis écrit les archives localement." 'BASE + FICHIERS'
Card 'database' 60 200 430 200
Icon 'icon-database' 'database' 80 225 64
Txt 'database-title' 'POSTGRESQL PRIMAIRE' 160 216 305 29 19 '#000000' $true
Txt 'database-endpoint' '192.168.33.161:5432' 160 257 305 34 24 '#000000' $true
Txt 'database-name' 'Base partagée : prod (par défaut)' 80 315 390 28 18
Txt 'database-role' 'Lecture SQL par pg_dump' 80 354 390 26 17

Card 'volume' 1110 200 430 200
Icon 'icon-volume' 'server' 1130 225 64
Txt 'volume-title' 'VOLUME GLUSTERFS · sre' 1210 216 305 29 19 '#000000' $true
Txt 'volume-endpoint' '192.168.36.8:/sre' 1210 257 305 34 24 '#000000' $true
Txt 'volume-data' 'Fichiers communs aux trois Odoo' 1130 315 390 28 18
Txt 'volume-client' "Accès par le client GlusterFS de l'hôte" 1130 354 390 26 16

Card 'backup-host' 560 200 480 470
Icon 'icon-backup-host' 'server' 580 216 52
Txt 'backup-host-title' 'HÔTE DE SAUVEGARDE' 650 216 365 29 20 '#000000' $true
Txt 'backup-host-address' '192.168.36.21' 650 253 365 34 26 '#000000' $true
Card 'mounted-volume' 585 310 430 90
Glyph 'icon-mounted-volume' 'folder' 603 325 50
Txt 'mounted-volume-title' 'VOLUME MONTÉ' 675 320 320 27 14 '#000000' $true
Txt 'mounted-volume-path' '/mnt/odoo' 675 353 320 40 27 '#000000' $true

Card 'backup-script' 585 450 430 155
Glyph 'icon-backup-script' 'file' 603 464 48
Txt 'backup-script-title' 'SCRIPT DE SAUVEGARDE' 670 465 330 29 19 '#000000' $true
Txt 'backup-script-steps' '0 · Vérifier le montage GlusterFS|1 · pg_dump de la base|2 · Archive des fichiers hors sessions' 610 517 380 76 17

Card 'sql-access-note' 60 425 430 65
Txt 'sql-access' 'Connexion depuis 192.168.36.21|vers 192.168.33.161 : TCP/5432' 80 432 390 50 17
Card 'precondition' 60 520 430 100
Txt 'precondition-title' 'PLAYBOOK : ansi_sauvegarde.yaml' 80 532 390 25 15 '#000000' $true
Txt 'precondition-body' 'Le volume doit être déjà monté.|Le script contrôle sa présence.' 80 567 390 46 17

Card 'exclusions' 1110 450 430 155
Glyph 'icon-excluded-sessions' 'folder' 1130 467 44
Txt 'exclusions-title' "EXCLUS DE L'ARCHIVE" 1190 465 325 29 17 '#000000' $true
Txt 'excluded-paths' './sessions et ./_sessions' 1130 513 390 30 21 '#000000' $true
Txt 'exclusions-caption' 'Le reste de /mnt/odoo est archivé.' 1130 559 390 28 17

Arrow 'database-to-script' @(@(490,300),@(525,300),@(525,528),@(585,528)) '#000000' $false $true 'database' 'backup-script'
Arrow 'volume-to-host' @(@(1110,300),@(1080,300),@(1080,355),@(1015,355)) '#000000' $false $true 'volume' 'mounted-volume'
Arrow 'volume-to-script' @(@(800,400),@(800,450)) '#000000' $false $true 'mounted-volume' 'backup-script'
Txt 'read-volume-label' 'Lecture du volume' 820 412 200 25 14
Arrow 'script-to-archives' @(@(800,605),@(800,730)) '#000000' $true $true 'backup-script' 'archives'
Txt 'write-archives-label' 'Écriture des fichiers de sauvegarde' 825 686 440 26 17 '#000000' $true

Card 'archives' 60 730 1480 185
Glyph 'icon-archives' 'folder' 85 744 70
Txt 'archives-path' '/srv/sauvegardes' 180 743 1320 37 28 '#000000' $true
Txt 'archives-location' "Stockage local sur 192.168.36.21 · archives séparées du volume GlusterFS" 180 788 1320 29 18
Card 'dump' 240 835 350 60
Icon 'icon-dump' 'database' 253 842 42
Txt 'dump-name' 'prod-<date>.dump' 310 849 260 31 19 '#000000' $true
Card 'archive' 625 835 350 60
Glyph 'icon-archive' 'archive' 638 842 42
Txt 'archive-name' 'filestore-<date>.tgz' 695 849 260 31 19 '#000000' $true
Card 'manifest' 1010 835 350 60
Glyph 'icon-manifest' 'file' 1023 842 42
Txt 'manifest-name' 'manifeste-<date>.txt' 1080 849 260 31 19 '#000000' $true

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
 [void]$svg.AppendLine(('<title id="title">'+(Esc $page.Name)+'</title><desc id="desc">Schéma GlusterFS et sauvegarde Odoo. Configuration du dépôt du 18 octobre 2026, serveurs non audités.</desc>'))
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
$drawio=Join-Path $OutputDirectory 'architecture-glusterfs-professionnelle.drawio'
$document.Save($drawio)
$parsed=[xml][System.IO.File]::ReadAllText($drawio)
if($parsed.SelectNodes('//diagram').Count -ne 3) { throw 'Le document doit contenir trois pages.' }
if($Warnings.Count -gt 0) { throw ('Débordements typographiques : '+($Warnings -join ' ; ')) }


$readme='# Schémas GlusterFS du projet Odoo

Configuration du dépôt au 18 octobre 2026. Les schémas décrivent les montages prévus par Ansible ; ils ne vérifient pas l''état des serveurs.

Ouvrir [architecture-glusterfs-professionnelle.drawio](architecture-glusterfs-professionnelle.drawio) dans draw.io / diagrams.net ou dans l''extension Draw.io de VS Code. Le document contient trois onglets modifiables, en noir et blanc, avec icônes vectorielles et quadrillage visible de 20 unités.

| Vue | Aperçu PNG | Version SVG |
| --- | --- | --- |
| Volume partagé entre les trois Odoo | [PNG](01-volume-partage-trois-odoo.png) | [SVG](01-volume-partage-trois-odoo.svg) |
| Montage sur l''hôte et bind LXC | [PNG](02-montage-hote-et-bind-lxc.png) | [SVG](02-montage-hote-et-bind-lxc.svg) |
| GlusterFS et sauvegarde | [PNG](03-glusterfs-et-sauvegarde.png) | [SVG](03-glusterfs-et-sauvegarde.svg) |

![Volume partagé](01-volume-partage-trois-odoo.png)

![Montage et bind LXC](02-montage-hote-et-bind-lxc.png)

![Sauvegarde Odoo](03-glusterfs-et-sauvegarde.png)

## Lire les schémas

- Trait plein : montage ou accès logique aux données.
- Trait pointillé : écriture des fichiers de sauvegarde.
- La grille apparaît dans le document draw.io et dans les exports ; ses lignes sont verrouillées.
- Les icônes, textes et connecteurs sont des éléments vectoriels modifiables.
- Le volume sre est externe au projet. Le serveur 192.168.36.8 fournit sa description ; les clients joignent ensuite directement les serveurs de briques indiqués par cette description.
- Les hôtes .36.21, .36.22 et .36.23 montent tous le même volume sur /mnt/odoo. Le groupe gluster_bricks désigne ici ces clients.
- Le bind vers /var/lib/odoo couvre le data_dir complet. Les chemins filestore/prod et sessions y sont donc partagés.
- prod est le nom de base par défaut, surchargeable par PROSYS_ODOO_DB.
- La sauvegarde est exécutée sur .36.21, depuis le montage hôte. Elle exclut ./sessions et ./_sessions et écrit dans /srv/sauvegardes.
- Le rapatriement vers le contrôleur est facultatif et désactivé par défaut ; il est hors de la vue principale.

## Configuration représentée

| Élément | Valeur | Source |
| --- | --- | --- |
| Point d''entrée du volume | 192.168.36.8:/sre | [Variables communes](../../group_vars/all/vars.yml) |
| Montage sur les hôtes | /mnt/odoo | [Variables Gluster](../../group_vars/gluster_bricks/vars.yml) |
| Destination LXC | /var/lib/odoo | [Rôle de montage](../../roles/ansi_odoo/odoo_filestore/tasks/main.yaml) |
| Répertoire de données Odoo | /var/lib/odoo | [Variables Odoo](../../group_vars/odoo_containers/vars.yml) |
| Montage avant installation Odoo | Étape 1bis/5 | [Déploiement Odoo](../../playbooks/ansi_odoo.yaml) |
| Hôte et répertoire de sauvegarde | .36.21, /srv/sauvegardes | [Inventaire](../../inventory.yaml), [variables sauvegarde](../../group_vars/backup_host/vars.yml) |
| Ordre et exclusions des archives | pg_dump puis archive hors sessions | [Script de sauvegarde](../../roles/ansi_sauvegarde/odoo_backup/templates/odoo-sauvegarde.sh.j2) |

Le rôle vérifie le type fuse.glusterfs sur l''hôte et dans le conteneur. Le montage représenté est la configuration cible ; les anciens montages éventuellement présents sur les serveurs n''ont pas été inspectés.

## Régénération

Depuis PowerShell sous Windows : .\generer-schemas.ps1

Le générateur utilise XML, SVG et System.Drawing, sans dépendance externe. Il produit les trois pages draw.io et les aperçus PNG 3200 × 2000 et SVG. Les modifications faites directement dans draw.io ne sont pas réimportées dans le générateur.
'
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.md'),$readme,[System.Text.UTF8Encoding]::new($false))
Write-Output 'Validation : 3 pages GlusterFS ; 3 SVG ; 3 PNG 3200 x 2000 ; textes sans débordement.'
Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name,Length
