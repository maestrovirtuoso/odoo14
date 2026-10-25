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
 Txt 'page-number' ($index+' / 04') 1400 960 140 25 14 $Muted $true 'right'
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
 Txt 'legend-access-label' 'Accès / étapes' 1013 143 205 23 13
 Arrow 'legend-copy' @(@(1250,154),@(1290,154)) '#000000' $true
 Txt 'legend-copy-label' 'WAL / contrôle' 1303 143 210 23 13
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




# Vue technique détaillée : zones réseau, placement et flux identifiés.
$script:Page=[pscustomobject]@{Slug='01-architecture-actuelle';Name='01 - Architecture technique expert';Width=2400;Height=1600;Items=[System.Collections.Generic.List[object]]::new()}
[void]$script:Pages.Add($script:Page)
Rect 'background' 0 0 2400 1600 '#FFFFFF' 'none' 0
for($gx=20;$gx -lt 2400;$gx+=20){
 $lineWidth=if($gx%100 -eq 0){0.30}else{0.12}
 Arrow ('grid-v-'+$gx) @(@($gx,0),@($gx,1600)) '#000000' $false $false '' '' $lineWidth $true
}
for($gy=20;$gy -lt 1600;$gy+=20){
 $lineWidth=if($gy%100 -eq 0){0.30}else{0.12}
 Arrow ('grid-h-'+$gy) @(@(0,$gy),@(2400,$gy)) '#000000' $false $false '' '' $lineWidth $true
}
Rect 'header' 0 0 2400 150 '#FFFFFF' 'none' 0
Txt 'category' 'ARCH-01 / ARCHITECTURE TECHNIQUE ODOO 14' 60 23 1800 26 16 '#000000' $true
Txt 'title' 'Vue de déploiement et flux de production' 60 56 1800 56 40 '#000000' $true
Txt 'subtitle' 'Configuration déclarée dans Ansible · six hôtes LXC · vue logique des réseaux, services et dépendances' 60 117 1850 28 20
Card 'status-tag' 1960 51 380 53
Txt 'status-tag-label' 'ACTUEL · BASCULE MANUELLE' 1975 62 350 31 20 '#000000' $true 'center'
Arrow 'header-rule' @(@(0,150),@(2400,150)) '#000000' $false $false '' '' 1

Card 'users' 60 190 650 110
Icon 'icon-users' 'browser' 85 210 64
Txt 'users-title' 'UTILISATEURS ODOO' 170 205 515 36 27 '#000000' $true
Txt 'users-description' 'Accès direct aux trois adresses des conteneurs' 170 255 515 29 19
Card 'controller' 890 190 630 110
Icon 'icon-controller' 'server' 915 210 64
Txt 'controller-title' 'CONTRÔLEUR ANSIBLE' 1000 205 495 36 27 '#000000' $true
Txt 'controller-description' 'SSH :22 · six hôtes et six conteneurs' 1000 255 495 29 19
Card 'reference' 1700 190 640 110
Txt 'reference-title' 'RÉFÉRENTIEL / STATUT DU DOCUMENT' 1725 203 590 28 16 '#000000' $true
Txt 'reference-body' 'Inventaire + variables Ansible · 25/10/2026|État réel des serveurs non contrôlé' 1725 245 590 46 18

Card 'application-zone' 60 370 1040 680
Icon 'icon-application-zone' 'network' 85 391 60
Txt 'application-zone-title' 'ZONE APPLICATION · 192.168.36.0/24' 170 386 900 38 29 '#000000' $true
Txt 'application-zone-description' "Passerelle .36.254 · IPVLAN L2 · MAC hôte partagée · NAT hôte désactivé" 170 437 900 29 19
Arrow 'application-zone-divider' @(@(85,472),@(1075,472)) '#000000' $false $false '' '' 1
Card 'database-zone' 1300 370 1040 680
Icon 'icon-database-zone' 'network' 1325 391 60
Txt 'database-zone-title' 'ZONE DONNÉES · 192.168.33.0/24' 1410 386 900 38 29 '#000000' $true
Txt 'database-zone-description' 'Passerelle .33.254 · IPVLAN L2 · NAT hôte désactivé · PostgreSQL 15' 1410 437 900 29 19

Arrow 'database-zone-divider' @(@(1325,472),@(2315,472)) '#000000' $false $false '' '' 1
for($i=1;$i -le 3;$i++){
 $left=85+($i-1)*345
 Card ('app-host-'+$i) $left 520 300 340
 Icon ('icon-app-host-'+$i) 'server' ($left+20) 530 42
 Txt ('app-host-title-'+$i) 'HÔTE DEBIAN 12' ($left+80) 534 200 30 18 '#000000' $true
 Txt ('app-host-ip-'+$i) ('192.168.36.2'+$i) ($left+20) 578 260 34 26 '#000000' $true
 Txt ('app-nic-'+$i) 'enp5s0 · IPVLAN L2' ($left+20) 623 260 26 17
 Card ('app-container-'+$i) ($left+20) 670 260 150
 Icon ('icon-app-container-'+$i) 'container' ($left+35) 683 38
 Txt ('app-container-name-'+$i) ('odoo'+$i) ($left+85) 681 180 31 24 '#000000' $true
 Txt ('app-container-ip-'+$i) ('192.168.36.16'+$i+'/24') ($left+35) 727 230 30 20 '#000000' $true
 Txt ('app-service-'+$i) 'HTTP :8069 · bus :8072' ($left+35) 766 230 24 15
 Txt ('app-data-dir-'+$i) '/var/lib/odoo (bind)' ($left+35) 793 230 21 14
 $operation=if($i -eq 1){'Initialisation + cron uniques'}else{'Odoo 14 · workers : 2'}
 Txt ('app-operation-'+$i) $operation ($left+20) 834 260 20 14

 $dbLeft=1325+($i-1)*345
 Card ('db-host-'+$i) $dbLeft 520 300 340
 Icon ('icon-db-host-'+$i) 'server' ($dbLeft+20) 530 42
 Txt ('db-host-title-'+$i) 'HÔTE DEBIAN 12' ($dbLeft+80) 534 200 30 18 '#000000' $true
 Txt ('db-host-ip-'+$i) ('192.168.33.2'+$i) ($dbLeft+20) 578 260 34 26 '#000000' $true
 Txt ('db-nic-'+$i) 'enp1s0 · IPVLAN L2' ($dbLeft+20) 623 260 26 17
 Card ('db-container-'+$i) ($dbLeft+20) 670 260 150
 Icon ('icon-db-container-'+$i) 'database' ($dbLeft+35) 683 38
 Txt ('db-container-name-'+$i) ('odoodb'+$i) ($dbLeft+85) 681 180 31 24 '#000000' $true
 Txt ('db-container-ip-'+$i) ('192.168.33.16'+$i+'/24') ($dbLeft+35) 727 230 30 20 '#000000' $true
 $dbRole=if($i -eq 1){'PRIMAIRE · lectures / écritures'}else{'RÉPLIQUE · lecture seule'}
 Txt ('db-role-'+$i) $dbRole ($dbLeft+35) 767 230 24 14 '#000000' $true
 Txt ('db-pg-port-'+$i) 'PostgreSQL :5432' ($dbLeft+35) 794 230 21 14
}
Card 'host-storage-mounts' 85 920 990 90
Glyph 'icon-host-mounts' 'folder' 105 938 54
Txt 'host-mounts-title' 'F03 / Clients GlusterFS sur les hôtes → /mnt/odoo' 180 928 870 31 23 '#000000' $true
Txt 'host-mounts-bind' 'Bind LXC → /var/lib/odoo · filestore et sessions communs aux trois Odoo' 180 971 870 27 19

Card 'replication-summary' 1325 920 990 90
Txt 'replication-summary-title' 'F04 / Deux répliques physiques alimentées par le primaire' 1350 930 940 31 23 '#000000' $true
Txt 'replication-summary-body' 'Slots odoodb2 / odoodb3 · bascule manuelle · aucune lecture Odoo dirigée vers les répliques' 1350 973 940 27 18

Card 'external-routing' 1120 630 160 240
Icon 'icon-external-routing' 'router' 1160 654 80
Txt 'routing-title' 'Routage L3' 1130 749 140 28 20 '#000000' $true 'center'
Txt 'routing-snat' 'SNAT vers|192.168.33.254' 1130 795 140 57 16 '#000000' $true 'center'
Txt 'routing-sql-note' 'F02 / SQL-TLS|TCP/5432|Certificat client' 1113 882 174 72 16 '#000000' $true 'center'

Arrow 'web-access' @(@(690,300),@(690,370)) '#000000' $false $true 'users' 'application-zone' 3
Txt 'web-flow-label' 'F01 / HTTP :8069 · longpolling :8072' 90 320 580 31 21 '#000000' $true
Arrow 'admin-app' @(@(1205,300),@(1205,335),@(1000,335),@(1000,370)) '#000000' $true $true 'controller' 'application-zone' 1.8
Arrow 'admin-db' @(@(1205,300),@(1205,335),@(1500,335),@(1500,370)) '#000000' $true $true 'controller' 'database-zone' 1.8
Txt 'admin-flow-label' 'F06 / Administration SSH :22' 1550 315 470 30 19 '#000000' $true
Arrow 'sql-app1' @(@(365,740),@(405,740),@(405,490),@(1090,490),@(1090,750),@(1120,750)) '#000000' $false $true 'app-container-1' 'external-routing' 3
Arrow 'sql-app2' @(@(710,740),@(750,740),@(750,490),@(1090,490),@(1090,750),@(1120,750)) '#000000' $false $true 'app-container-2' 'external-routing' 3
Arrow 'sql-app3' @(@(1055,740),@(1090,740),@(1090,750),@(1120,750)) '#000000' $false $true 'app-container-3' 'external-routing' 3
Txt 'sql-app-label' 'F02 / SQL-TLS vers le primaire' 780 494 300 24 16 '#000000' $true 'center'
Arrow 'sql-primary' @(@(1280,750),@(1310,750),@(1310,740),@(1345,740)) '#000000' $false $true 'external-routing' 'db-container-1' 3
Arrow 'wal-db2' @(@(1475,820),@(1475,890),@(1820,890),@(1820,820)) '#000000' $true $true 'db-container-1' 'db-container-2'
Arrow 'wal-db3' @(@(1475,820),@(1475,890),@(2165,890),@(2165,820)) '#000000' $true $true 'db-container-1' 'db-container-3'
Txt 'wal-flow-label' 'F04 / Streaming WAL · TCP/5432' 1655 893 560 24 17 '#000000' $true 'center'
for($i=1;$i -le 3;$i++){
 $center=235+($i-1)*345
 Arrow ('mount-to-host-'+$i) @(@(580,920),@(580,895),@($center,895),@($center,860)) '#000000' $false $true 'host-storage-mounts' ('app-host-'+$i) 1.8
}

Card 'external-storage' 60 1140 1040 230
Icon 'icon-external-storage' 'server' 90 1168 66
Txt 'external-storage-title' 'STOCKAGE EXTERNE / volume sre' 180 1160 890 38 29 '#000000' $true
Txt 'external-storage-endpoint' 'Description du volume : 192.168.36.8:/sre' 180 1210 890 34 25 '#000000' $true
Txt 'external-storage-description' 'Les clients joignent directement les serveurs de briques décrits par le volume.|La topologie et la redondance des briques sont gérées hors de ce dépôt.' 90 1270 980 64 20
Arrow 'storage-to-mounts' @(@(580,1140),@(580,1010)) '#000000' $false $true 'external-storage' 'host-storage-mounts' 1.8
Txt 'storage-flow-label' 'F03 / TCP :24007 + ports effectifs des briques' 610 1061 485 30 18 '#000000' $true

Card 'backup-service' 1300 1140 1040 230
Glyph 'icon-backup-service' 'folder' 1330 1168 66
Txt 'backup-title' 'SAUVEGARDE / hôte 192.168.36.21' 1420 1160 890 38 29 '#000000' $true
Txt 'backup-directory' '/srv/sauvegardes' 1420 1210 890 34 27 '#000000' $true
Txt 'backup-description' 'Dump du primaire + archive /mnt/odoo hors sessions et _sessions.|Rôle configuré : accès SQL/TLS et restauration à valider.' 1330 1270 980 64 20
Arrow 'backup-to-database' @(@(1810,1140),@(1810,1090),@(1290,1090),@(1290,810),@(1345,810)) '#000000' $true $true 'backup-service' 'db-container-1' 1.8
Txt 'backup-sql-label' 'F05a / Dump du primaire :5432 · accès à valider' 1425 1060 610 28 18 '#000000' $true
Arrow 'backup-to-host-mount' @(@(1300,1270),@(1160,1270),@(1160,970),@(1075,970)) '#000000' $true $true 'backup-service' 'host-storage-mounts' 1.8
Txt 'backup-files-label' 'F05b / /mnt/odoo sur hôte .36.21' 1190 1100 535 27 17 '#000000' $true 'left'

Card 'current-availability' 60 1420 720 110
Txt 'current-availability-title' 'DISPONIBILITÉ SÉLECTIONNÉE' 82 1429 676 27 16 '#000000' $true
Txt 'current-availability-body' 'pg_ha_enabled=false · primaire SQL et cron odoo1 uniques.|Bascule manuelle ; réplication asynchrone.' 82 1471 676 47 18

Card 'conventions' 840 1420 720 110
Txt 'conventions-title' 'CONVENTIONS / IDENTIFIANTS DE FLUX' 862 1429 676 27 16 '#000000' $true
Arrow 'legend-data' @(@(862,1476),@(922,1476)) '#000000' $false $true '' '' 2.5
Txt 'legend-data-label' 'Accès applicatif, SQL ou montage' 942 1462 590 28 18
Arrow 'legend-secondary' @(@(862,1510),@(922,1510)) '#000000' $true $true '' '' 1.8
Txt 'legend-secondary-label' 'WAL, gestion ou sauvegarde déclarée' 942 1496 590 28 18

Card 'ha-option' 1620 1420 720 110
Txt 'ha-option-title' 'OPTION HA / HORS DU CHEMIN SQL ACTUEL' 1642 1429 676 27 16 '#000000' $true
Txt 'ha-option-body' 'Patroni + etcd + HAProxy :5000.|Rôle présent ; activation et validation à réaliser.' 1642 1471 676 47 18
Arrow 'footer-rule' @(@(60,1560),@(2340,1560)) '#000000' $false $false '' '' 1
Txt 'footer' 'Source : dépôt Ansible au 25 octobre 2026 · architecture déclarée, serveurs non audités · domaines physiques de panne non décrits' 60 1570 1870 23 15
Txt 'page-number' 'ARCH-01 / 2400 × 1600' 1970 1570 370 23 15 '#000000' $true 'right'


New-GridPage '02-replication-et-bascule-manuelle' '02 - Réplication actuelle et bascule manuelle' '02' 'DISPONIBILITÉ ACTUELLE' 'Un primaire, deux répliques en streaming' 'Configuration sélectionnée : pg_server ; les clients écrivent uniquement sur odoodb1.' 'BASCULE MANUELLE'
Card 'status' 60 175 1480 65
Txt 'status-label' 'MODE DÉCLARÉ : pg_ha_enabled = false · aucune promotion automatique dans cette branche' 85 190 1420 35 21 '#000000' $true
Card 'clients' 60 280 430 150
Icon 'icon-clients' 'browser' 80 295 60
Txt 'clients-title' 'odoo1 / odoo2 / odoo3' 160 296 305 32 22 '#000000' $true
Txt 'clients-endpoint' '192.168.33.161:5432' 80 362 390 36 26 '#000000' $true
Card 'primary' 590 280 420 210
Icon 'icon-primary' 'database' 610 300 58
Txt 'primary-title' 'odoodb1 · PRIMAIRE' 690 296 295 31 21 '#000000' $true
Txt 'primary-ip' '192.168.33.161' 690 340 295 38 26 '#000000' $true
Txt 'primary-details' 'Lectures et écritures SQL|Hôte : 192.168.33.21 · PostgreSQL 15' 610 410 375 58 17
Card 'replica2' 1120 280 420 150
Icon 'icon-replica2' 'database' 1140 298 46
Txt 'replica2-title' 'odoodb2 · RÉPLIQUE' 1210 295 305 30 21 '#000000' $true
Txt 'replica2-ip' '192.168.33.162' 1210 337 305 34 24 '#000000' $true
Txt 'replica2-details' 'Hôte .33.22 · lecture seule · slot odoodb2' 1140 391 375 24 15
Card 'replica3' 1120 470 420 150
Icon 'icon-replica3' 'database' 1140 488 46
Txt 'replica3-title' 'odoodb3 · RÉPLIQUE' 1210 485 305 30 21 '#000000' $true
Txt 'replica3-ip' '192.168.33.163' 1210 527 305 34 24 '#000000' $true
Txt 'replica3-details' 'Hôte .33.23 · lecture seule · slot odoodb3' 1140 581 375 24 15
Arrow 'client-sql' @(@(490,355),@(590,355)) '#000000' $false $true 'clients' 'primary'
Txt 'sql-label' 'SQL' 498 315 85 25 15 '#000000' $true 'center'
Arrow 'wal-2' @(@(1010,355),@(1120,355)) '#000000' $true $true 'primary' 'replica2'
Txt 'wal-label-2' 'WAL' 1012 314 106 26 15 '#000000' $true 'center'
Arrow 'wal-3' @(@(800,490),@(800,545),@(1120,545)) '#000000' $true $true 'primary' 'replica3'
Txt 'wal-label-3' 'WAL asynchrones' 900 503 200 27 16 '#000000' $true
Card 'replica-note' 60 470 430 150
Txt 'replica-note-title' 'RÉSERVES SUR DEUX HÔTES DISTINCTS' 80 487 390 27 15 '#000000' $true
Txt 'replica-note-body' 'Odoo reste connecté au primaire.|Les répliques conservent des copies|en lecture seule de la base.' 80 532 390 78 18
Card 'async-note' 60 640 1480 40
Txt 'async-note-text' 'Réplication asynchrone : les dernières transactions peuvent manquer sur une réplique au moment de la panne.' 82 647 1435 27 18 '#000000' $true
Card 'manual-process' 60 700 1480 160
Txt 'manual-process-title' 'EN CAS DE PANNE DU PRIMAIRE : INTERVENTION MANUELLE' 85 712 1420 25 14 '#000000' $true
$manualTitles=@('1 · Isoler le primaire','2 · Promouvoir une réserve','3 · Modifier les clients',"4 · Réintégrer l'ancien")
$manualBodies=@("Éviter son retour en écriture.","Choisir une réserve à jour.",'Odoo, sauvegardes et réplication.','Reconstruction / reprise contrôlée.')
for($i=0;$i -lt 4;$i++){
 $left=85+$i*370
 Card ('manual-step-'+$i) $left 750 320 90
 Txt ('manual-step-title-'+$i) $manualTitles[$i] ($left+16) 758 288 28 17 '#000000' $true
 Txt ('manual-step-body-'+$i) $manualBodies[$i] ($left+16) 800 288 25 15
 if($i -lt 3){ Arrow ('manual-arrow-'+$i) @(@(($left+320),795),@(($left+370),795)) }
}
Txt 'manual-outage' "Sans intervention, la panne d'odoodb1 interrompt les accès SQL d'Odoo malgré les deux répliques." 80 893 1440 31 20 '#000000' $true

New-GridPage '03-option-ha-patroni-etcd-haproxy' '03 - Option HA Patroni etcd HAProxy' '03' 'HA PRÉVUE DANS LE DÉPÔT' 'Patroni, etcd et trois points d''entrée SQL' 'Exemple de placement initial : odoodb1 primaire ; Patroni pourra désigner un autre nœud.' 'OPTION HA'
Card 'ha-status' 60 175 1480 60
Txt 'ha-status-text' 'OPTION NON ACTIVÉE · pg_ha_enabled = false · code présent, tests et déploiement à réaliser' 85 189 1420 33 21 '#000000' $true
Card 'ha-clients' 60 265 1480 80
Icon 'icon-ha-clients' 'browser' 80 278 48
Txt 'ha-clients-title' 'Clients Odoo · libpq' 150 273 350 32 23 '#000000' $true
Txt 'ha-clients-list' '192.168.33.161,192.168.33.162,192.168.33.163 :5000' 520 274 990 28 21 '#000000' $true
Txt 'ha-clients-policy' "Essai des adresses dans l'ordre · PGTARGETSESSIONATTRS=read-write" 520 309 990 24 16
for($i=1;$i -le 3;$i++){
 $left=60+($i-1)*530
 Card ('ha-node-'+$i) $left 410 420 365
 Icon ('icon-ha-node-'+$i) 'server' ($left+25) 424 44
 Txt ('ha-node-title-'+$i) ('odoodb'+$i+' · 192.168.33.16'+$i) ($left+90) 425 305 30 19 '#000000' $true
 Txt ('ha-node-host-'+$i) ('Hôte 192.168.33.2'+$i+' · LXC devpg15') ($left+25) 471 370 25 15
 Card ('haproxy-'+$i) ($left+25) 510 370 47
 Txt ('haproxy-label-'+$i) 'HAProxy :5000 → primaire' ($left+45) 518 330 29 20 '#000000' $true
 Card ('ha-pg-'+$i) ($left+25) 580 370 50
 Icon ('icon-ha-pg-'+$i) 'database' ($left+40) 586 38
 $role=if($i -eq 1){'PRIMAIRE'}else{'RÉPLIQUE'}
 Txt ('ha-pg-label-'+$i) ('PostgreSQL :5432 · '+$role) ($left+95) 589 280 31 18 '#000000' $true
 Card ('patroni-'+$i) ($left+25) 650 370 44
 Txt ('patroni-label-'+$i) 'Patroni API :8008 /primary' ($left+45) 657 330 29 18 '#000000' $true
 Card ('etcd-'+$i) ($left+25) 710 370 44
 Txt ('etcd-label-'+$i) 'etcd :2379 / :2380' ($left+45) 717 330 29 18 '#000000' $true
 $center=$left+210
 Arrow ('clients-to-node-'+$i) @(@($center,345),@($center,410)) '#000000' $false $true 'ha-clients' ('ha-node-'+$i)
 Txt ('endpoint-label-'+$i) 'Entrée TCP/5000' ($center-115) 368 230 25 16 '#000000' $true 'center'
 Arrow ('patroni-to-etcd-'+$i) @(@($center,694),@($center,710)) '#000000' $true $true ('patroni-'+$i) ('etcd-'+$i)
}
Arrow 'proxy1-to-primary' @(@(270,557),@(270,580)) '#000000' $false $true 'haproxy-1' 'ha-pg-1'
Arrow 'proxy2-to-primary' @(@(800,557),@(800,567),@(270,567),@(270,580)) '#000000' $false $true 'haproxy-2' 'ha-pg-1'
Arrow 'proxy3-to-primary' @(@(1330,557),@(1330,567),@(270,567),@(270,580)) '#000000' $false $true 'haproxy-3' 'ha-pg-1'
Arrow 'ha-wal2' @(@(405,630),@(405,640),@(800,640),@(800,630)) '#000000' $true $true 'ha-pg-1' 'ha-pg-2'
Arrow 'ha-wal3' @(@(405,630),@(405,640),@(1330,640),@(1330,630)) '#000000' $true $true 'ha-pg-1' 'ha-pg-3'
Arrow 'etcd-members-12' @(@(455,732),@(615,732)) '#000000' $true $false 'etcd-1' 'etcd-2'
Arrow 'etcd-members-23' @(@(985,732),@(1145,732)) '#000000' $true $false 'etcd-2' 'etcd-3'
Txt 'quorum-label' 'etcd : trois membres · quorum requis de 2 sur 3' 60 791 1480 29 21 '#000000' $true 'center'
Card 'ha-notes' 60 840 1480 82
Txt 'ha-notes-1' 'HAProxy interroge Patroni (GET /primary, 8008) ; Patroni gère PostgreSQL et le verrou du leader dans etcd.' 85 847 1420 28 18 '#000000' $true
Txt 'ha-notes-2' 'TLS SQL de bout en bout · streaming WAL asynchrone · aucun équilibrage des lectures vers les répliques · aucune VIP.' 85 885 1420 26 17

New-GridPage '04-bascule-ha-et-quorum' '04 - Bascule HA et limites de disponibilité' '04' 'SCÉNARIO HA PRÉVU' "Panne du primaire : élection puis reconnexion" 'Scénario illustratif sous Patroni ; il ne décrit pas un test de panne exécuté sur les serveurs.' 'OPTION HA'
Card 'failover-status' 60 175 1480 60
Txt 'failover-status-text' "HA NON ACTIVÉE · exemple : perte d'odoodb1 et promotion conditionnelle d'odoodb2" 85 189 1420 33 21 '#000000' $true
Card 'failed-node' 60 285 420 210
Icon 'icon-failed-node' 'server' 80 309 58
Arrow 'failed-cross-1' @(@(80,309),@(138,367)) '#000000' $false $false '' '' 3
Arrow 'failed-cross-2' @(@(138,309),@(80,367)) '#000000' $false $false '' '' 3
Txt 'failed-title' 'odoodb1 · INDISPONIBLE' 150 297 305 30 20 '#000000' $true
Txt 'failed-ip' '192.168.33.161' 150 340 305 37 26 '#000000' $true
Txt 'failed-details' 'PostgreSQL, Patroni et etcd indisponibles.' 85 394 370 27 16
Txt 'failed-proxy' 'HAProxy local également perdu ici.' 85 438 370 25 16
Card 'new-primary' 590 285 420 210
Icon 'icon-new-primary' 'database' 610 309 58
Txt 'new-primary-title' 'odoodb2 · PRIMAIRE ÉLU' 680 297 305 30 20 '#000000' $true
Txt 'new-primary-ip' '192.168.33.162' 680 340 305 37 26 '#000000' $true
Txt 'new-primary-condition' 'Promotion par Patroni sous conditions.' 615 394 370 27 16
Txt 'new-primary-quorum' 'etcd2 et etcd3 : majorité disponible.' 615 438 370 25 16
Card 'remaining-replica' 1120 285 420 210
Icon 'icon-remaining-replica' 'database' 1140 309 58
Txt 'remaining-title' 'odoodb3 · RÉPLIQUE' 1210 297 305 30 20 '#000000' $true
Txt 'remaining-ip' '192.168.33.163' 1210 340 305 37 26 '#000000' $true
Txt 'remaining-stream' 'Suit le nouveau primaire en streaming.' 1145 394 370 27 16
Txt 'remaining-service' 'HAProxy et etcd restent disponibles.' 1145 438 370 25 16
Arrow 'new-wal' @(@(1010,390),@(1120,390)) '#000000' $true $true 'new-primary' 'remaining-replica'
Txt 'new-wal-label' 'WAL' 1014 344 102 27 16 '#000000' $true 'center'
Card 'reconnect-clients' 60 550 420 100
Icon 'icon-reconnect-clients' 'browser' 80 565 48
Txt 'reconnect-title' 'Clients Odoo' 145 562 310 29 20 '#000000' $true
Txt 'reconnect-policy' 'Réessai sur une adresse disponible.' 145 606 310 25 16
Card 'available-proxies' 590 550 420 100
Icon 'icon-available-proxies' 'network' 610 565 48
Txt 'available-proxies-title' 'HAProxy .33.162 / .33.163' 680 562 305 29 19 '#000000' $true
Txt 'available-proxies-policy' 'Cible : le primaire courant.' 680 606 305 25 16
Card 'quorum-condition' 1120 550 420 100
Icon 'icon-quorum' 'network' 1140 565 48
Txt 'quorum-title' 'QUORUM : 2 SUR 3' 1210 562 305 29 20 '#000000' $true
Txt 'quorum-condition-text' 'Deux membres doivent communiquer.' 1210 606 305 25 15
Arrow 'clients-reconnect' @(@(480,600),@(590,600)) '#000000' $false $true 'reconnect-clients' 'available-proxies'
Arrow 'proxy-to-new-primary' @(@(800,550),@(800,495)) '#000000' $false $true 'available-proxies' 'new-primary'
Txt 'proxy-new-endpoint' 'SQL relayé vers .33.162:5432' 825 508 360 27 16 '#000000' $true
Card 'failover-sequence' 60 705 1480 165
Txt 'failover-sequence-title' 'ENCHAÎNEMENT ATTENDU, À VALIDER PAR DES TESTS' 85 714 1420 26 14 '#000000' $true
$stepTitles=@('1 · Perte du primaire','2 · Verrou et élection','3 · Promotion + routage','4 · Reconnexion Odoo')
$stepBodies=@('Sessions SQL coupées|ou connexions en erreur','Majorité etcd et réserve|éligible nécessaires','Patroni promeut ; HAProxy|repère le nouveau primaire','Les clients ouvrent de|nouvelles connexions SQL')
for($i=0;$i -lt 4;$i++){
 $left=85+$i*370
 Card ('failover-step-'+$i) $left 750 320 95
 Txt ('failover-step-title-'+$i) $stepTitles[$i] ($left+16) 758 288 28 17 '#000000' $true
 Txt ('failover-step-body-'+$i) $stepBodies[$i] ($left+16) 798 288 39 15
 if($i -lt 3){ Arrow ('failover-arrow-'+$i) @(@(($left+320),795),@(($left+370),795)) }
}
Card 'ha-limits' 60 895 1480 35
Txt 'ha-limits-text' 'Asynchrone : pertes possibles · pas de fencing matériel · durée à mesurer · certificats de sauvegarde HA à compléter.' 80 899 1440 27 17 '#000000' $true

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
 $pageWidth=if($page.PSObject.Properties.Name -contains 'Width'){[int]$page.Width}else{1600}
 $pageHeight=if($page.PSObject.Properties.Name -contains 'Height'){[int]$page.Height}else{1000}
 $diagram=$document.CreateElement('diagram')
 $diagram.SetAttribute('id',$page.Slug); $diagram.SetAttribute('name',$page.Name)
 [void]$rootFile.AppendChild($diagram)
 $model=$document.CreateElement('mxGraphModel')
 foreach ($attribute in @{dx=[string]$pageWidth;dy=[string]$pageHeight;grid='1';gridSize='20';guides='1';tooltips='1';connect='1';arrows='1';fold='1';page='1';pageScale='1';pageWidth=[string]$pageWidth;pageHeight=[string]$pageHeight;background=$Bg}.GetEnumerator()) { $model.SetAttribute($attribute.Key,$attribute.Value) }
 [void]$diagram.AppendChild($model)
 $root=$document.CreateElement('root'); [void]$model.AppendChild($root)
 foreach($pair in @(@('0',''),@('1','0'))) {
  $base=$document.CreateElement('mxCell'); $base.SetAttribute('id',$pair[0])
  if($pair[1]) { $base.SetAttribute('parent',$pair[1]) }
  [void]$root.AppendChild($base)
 }
 $svg=[System.Text.StringBuilder]::new()
 [void]$svg.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" width="'+$pageWidth+'" height="'+$pageHeight+'" viewBox="0 0 '+$pageWidth+' '+$pageHeight+'" role="img" aria-labelledby="title desc">')
 [void]$svg.AppendLine(('<title id="title">'+(Esc $page.Name)+'</title><desc id="desc">Architecture Odoo actuelle et option haute disponibilité PostgreSQL. Configuration du dépôt du 25 octobre 2026, serveurs non audités.</desc>'))
 $bitmap=[System.Drawing.Bitmap]::new(($pageWidth*2),($pageHeight*2))
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
    $rectWidth=if($item.Id -in @('application-zone','database-zone')){2.5}else{1.5}
    $rectWidthText=$rectWidth.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $cell.SetAttribute('style',"rounded=$rounded;arcSize=$($item.Radius);absoluteArcSize=1;whiteSpace=wrap;html=0;fillColor=$($item.Fill);strokeColor=$($item.Stroke);strokeWidth=$rectWidthText;")
    if($item.Id -in @('background','header')) { $cell.SetAttribute('style',$cell.GetAttribute('style')+'locked=1;') }
    [void]$svg.AppendLine('<rect x="'+$item.X+'" y="'+$item.Y+'" width="'+$item.W+'" height="'+$item.H+'" rx="'+$item.Radius+'" fill="'+$item.Fill+'" stroke="'+$item.Stroke+'" stroke-width="'+$rectWidthText+'"/>')
    $shape=RoundedPath $item.X $item.Y $item.W $item.H $item.Radius
    if($item.Fill -ne 'none') { $brush=[System.Drawing.SolidBrush]::new((Color $item.Fill)); $graphics.FillPath($brush,$shape); $brush.Dispose() }
    if($item.Stroke -ne 'none') { $pen=[System.Drawing.Pen]::new((Color $item.Stroke),[single]$rectWidth); $graphics.DrawPath($pen,$shape); $pen.Dispose() }
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
  if($item.X -lt 0 -or $item.Y -lt 0 -or $item.X+$item.W -gt $pageWidth -or $item.Y+$item.H -gt $pageHeight) { throw "Élément hors page : $($page.Slug)/$($item.Id)" }
 }
}
$drawio=Join-Path $OutputDirectory 'architecture-actuelle-et-ha-postgresql.drawio'
$document.Save($drawio)
$single=[System.Xml.XmlDocument]::new()
$single.LoadXml('<mxfile host="app.diagrams.net" type="device"/>')
[void]$single.DocumentElement.AppendChild($single.ImportNode($document.SelectSingleNode('/mxfile/diagram[1]'),$true))
$single.Save((Join-Path $OutputDirectory 'architecture-actuelle-expert.drawio'))
$parsed=[xml][System.IO.File]::ReadAllText($drawio)
if($parsed.SelectNodes('//diagram').Count -ne 4) { throw 'Le document doit contenir quatre pages.' }
if($Warnings.Count -gt 0) { throw ('Débordements typographiques : '+($Warnings -join ' ; ')) }



$readme='# Architecture actuelle et disponibilité PostgreSQL

Configuration du dépôt au **25 octobre 2026**. Les schémas représentent les fichiers Ansible, sans audit des serveurs.

**État déclaré : pg_ha_enabled=false.** Odoo vise odoodb1 en direct sur 5432. Le rôle Patroni/etcd/HAProxy existe comme option ; la documentation du projet le décrit au 23 octobre comme écrit, non testé et non déployé. Les vues 3 et 4 représentent cette option et un scénario illustratif, pas une HA constatée en exploitation.

La **vue de déploiement expert** est disponible seule dans [architecture-actuelle-expert.drawio](architecture-actuelle-expert.drawio), au format paysage 2400 × 1600. Les zones réseau, limites des hôtes et conteneurs, flux identifiés et dépendances sont explicités.

Ouvrir [architecture-actuelle-et-ha-postgresql.drawio](architecture-actuelle-et-ha-postgresql.drawio) dans draw.io / diagrams.net ou dans l''extension Draw.io de VS Code. Les quatre onglets sont modifiables : noir et blanc, grille visible de 20 unités, icônes vectorielles.

| Vue | Aperçu PNG | Version SVG |
| --- | --- | --- |
| Architecture technique expert · 2400 × 1600 | [PNG](01-architecture-actuelle.png) | [SVG](01-architecture-actuelle.svg) |
| Réplication et bascule manuelle | [PNG](02-replication-et-bascule-manuelle.png) | [SVG](02-replication-et-bascule-manuelle.svg) |
| Option HA Patroni / etcd / HAProxy | [PNG](03-option-ha-patroni-etcd-haproxy.png) | [SVG](03-option-ha-patroni-etcd-haproxy.svg) |
| Bascule HA et quorum | [PNG](04-bascule-ha-et-quorum.png) | [SVG](04-bascule-ha-et-quorum.svg) |

![Architecture technique expert](01-architecture-actuelle.png)

![Réplication actuelle](02-replication-et-bascule-manuelle.png)

![Option HA](03-option-ha-patroni-etcd-haproxy.png)

![Bascule HA](04-bascule-ha-et-quorum.png)

## Lecture de la vue expert

Les flèches portent un identifiant stable. Les traits pleins décrivent les accès applicatifs, SQL et stockage ; les pointillés décrivent la réplication, la gestion ou les sauvegardes déclarées.

| Flux | Source → destination | Protocole / usage |
| --- | --- | --- |
| F01 | Utilisateurs → conteneurs Odoo | TCP/8069, TCP/8072 pour le bus |
| F02 | Odoo → routeur externe → odoodb1 | SQL TCP/5432, TLS verify-full et certificat client ; SNAT externe .33.254 |
| F03 | Clients GlusterFS des hôtes → serveurs externes | Description du volume via .36.8:24007, puis ports effectifs des briques ; montage /mnt/odoo et bind vers /var/lib/odoo |
| F04 | odoodb1 → odoodb2 et odoodb3 | Réplication physique WAL asynchrone, TCP/5432 |
| F05a | Sauvegarde sur .36.21 → primaire | pg_dump TCP/5432 ; accès SQL/TLS à valider |
| F05b | Sauvegarde sur .36.21 → montage local | Lecture de /mnt/odoo sur le même hôte, hors sessions et _sessions |
| F06 | Contrôleur Ansible → hôtes et conteneurs | Administration SSH TCP/22 |

Les flèches de montage F03 illustrent la dépendance au volume. Les clients GlusterFS résident sur les hôtes, et les conteneurs reçoivent un bind du montage. Le bloc de montage est une représentation groupée des trois clients, pas un équipement supplémentaire.

Les hôtes LXC sont distincts dans l''inventaire. Leur placement physique et leurs domaines de panne ne sont pas décrits. La topologie et la redondance des briques GlusterFS restent externes au dépôt. La sauvegarde est configurée ; son accès SQL/TLS et une restauration doivent être validés avant de la considérer opérationnelle.

## Architecture déclarée

| Service | Conteneur | Hôte LXC |
| --- | --- | --- |
| Odoo 1, initialisation et cron | 192.168.36.161 | 192.168.36.21 |
| Odoo 2 | 192.168.36.162 | 192.168.36.22 |
| Odoo 3 | 192.168.36.163 | 192.168.36.23 |
| PostgreSQL primaire odoodb1 | 192.168.33.161 | 192.168.33.21 |
| Réplique odoodb2 | 192.168.33.162 | 192.168.33.22 |
| Réplique odoodb3 | 192.168.33.163 | 192.168.33.23 |

Les interfaces LXC utilisent IPVLAN L2, sans NAT sur les hôtes. Le routeur externe effectue en revanche un SNAT vers 192.168.33.254 selon la configuration récente du dépôt. Pour les connexions Odoo, PostgreSQL exige un certificat client et le client vérifie le serveur en TLS.

Les trois hôtes Odoo montent le volume GlusterFS externe sre sur /mnt/odoo et le présentent aux conteneurs sur /var/lib/odoo. 192.168.36.8 fournit la description du volume ; les clients communiquent ensuite directement avec les serveurs de briques. Le détail de ces serveurs reste externe au dépôt.

Les utilisateurs accèdent directement aux Odoo sur 8069 ; le bus utilise 8072. Aucun répartiteur HTTP ou VIP applicative n''est représenté. La sauvegarde est déclarée sur .36.21 dans /srv/sauvegardes, avec dump SQL et archive du volume hors sessions.

## Disponibilité actuelle et option HA

| Point | Branche actuelle | Option Patroni |
| --- | --- | --- |
| Sélection | pg_ha_enabled=false | Activation après reprise et validation |
| Connexion Odoo | .33.161:5432 | .33.161,.33.162,.33.163:5000 via libpq |
| Gestion du primaire | Rôle pg_server, placement fixe | Patroni et verrou dans etcd |
| Panne du primaire | Intervention manuelle | Promotion automatique sous conditions |
| Réplication | Streaming asynchrone, deux slots | Streaming asynchrone géré par Patroni |
| Routage SQL | Adresse directe du primaire | Trois HAProxy dirigés vers le primaire courant |

En HA, chaque conteneur PostgreSQL porte PostgreSQL, Patroni, etcd et HAProxy. Les trois HAProxy ne répartissent pas les lectures entre les répliques. Ils utilisent GET /primary sur l''API Patroni pour sélectionner le primaire détenteur du verrou. [API Patroni](https://patroni.readthedocs.io/en/latest/rest_api.html)

| Port HA | Flux |
| --- | --- |
| 5000/TCP | Clients Odoo vers les trois HAProxy |
| 5432/TCP | HAProxy vers PostgreSQL et streaming entre serveurs |
| 8008/HTTP | Contrôles et API Patroni |
| 2379/HTTPS | Patroni vers etcd |
| 2380/HTTPS | Consensus entre membres etcd |
| 7000/HTTP | Statistiques HAProxy sur 127.0.0.1 uniquement |

Le TLS PostgreSQL traverse HAProxy sans terminaison. Les certificats SQL couvrent les trois adresses. Etcd utilise une autorité de certification distincte ; l''API Patroni reste en HTTP.

## Conditions et limites représentées

- La majorité etcd exige **2 membres sur 3**. Une réserve doit être éligible pour devenir primaire ; sans majorité, aucune bascule automatique sûre ne peut être décidée.
- Le scénario de la page 4 choisit odoodb2 comme exemple. Ce n''est ni une préférence imposée ni le résultat d''un test.
- La réplication reste asynchrone : des transactions récentes peuvent être perdues. maximum_lag_on_failover=1048576 est un seuil d''éligibilité, **pas une garantie de perte maximale de 1 Mio**. [Modes de réplication Patroni](https://patroni.readthedocs.io/en/latest/replication_modes.html)
- Les réglages sont ttl=30 s, loop_wait=10 s et contrôles HAProxy toutes les 3 s. Le temps réel de rétablissement n''a pas été mesuré ; les requêtes et transactions en cours peuvent échouer.
- watchdog.mode=off : aucun fencing matériel n''est configuré. La relance systemd de Patroni ne couvre pas tous les blocages. [Protection du primaire](https://patroni.readthedocs.io/en/latest/watchdog.html)
- Le rôle sauvegarde prépare les endpoints HA mais ne déploie pas le certificat client ni l''environnement TLS exigés pour pg_dump via HAProxy. Cette partie reste à compléter et valider.
- Après une promotion, db_containers et db_replicas décrivent le placement initial ; les scripts qui s''appuient sur ces groupes doivent être réexaminés. L''ancien primaire doit être réintégré sous contrôle ; pg_rewind nécessite ses préconditions.
- La HA SQL ne rend pas automatiquement disponibles le cron porté par odoo1, les accès web, GlusterFS ou l''infrastructure physique.

## Sources du projet

- [Inventaire](../../inventory.yaml) et [variables communes](../../group_vars/all/vars.yml).
- [Playbook Odoo](../../playbooks/ansi_odoo.yaml).
- [Rôle PostgreSQL actuel](../../roles/ansi_odoo/pg_server/tasks/main.yaml), [réplication](../../roles/ansi_odoo/pg_server/templates/20-replication.conf.j2).
- [Playbook HA](../../playbooks/ansi_postgresql_ha.yaml), [paramètres Patroni / etcd](../../roles/ansi_postgresql_ha/pg_ha/defaults/main.yml), [HAProxy](../../roles/ansi_postgresql_ha/pg_ha/templates/haproxy.cfg.j2).
- [Documentation HA du projet](../POSTGRESQL-PATRONI.md).
- [Montage GlusterFS](../../roles/ansi_odoo/odoo_filestore/tasks/main.yaml), [variables sauvegarde](../../group_vars/backup_host/vars.yml), [rôle sauvegarde](../../roles/ansi_sauvegarde/odoo_backup/tasks/main.yaml).

## Régénération

Depuis PowerShell sous Windows : .\generer-schemas.ps1

Le générateur autonome utilise XML, SVG et System.Drawing. Il produit le document à quatre pages, la vue expert autonome, les SVG et les PNG (4800 × 3200 pour la vue expert, 3200 × 2000 pour les trois vues de disponibilité), et vérifie le texte et les limites de page. Les changements effectués dans draw.io ne sont pas réimportés dans le générateur.
'
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.md'),$readme,[System.Text.UTF8Encoding]::new($false))
Write-Output 'Validation : 4 pages + vue expert autonome ; 4 SVG ; 4 PNG ; aucun débordement de texte.'
Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name,Length
