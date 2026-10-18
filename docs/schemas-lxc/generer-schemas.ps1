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

New-Page '01-raccordement-ipvlan' '01 - Raccordement IPVLAN' '01' 'RACCORDEMENT' 'Un conteneur, une IP dédiée' "IPVLAN L2 partage la carte réseau et l'adresse MAC de l'hôte." 'IPVLAN / L2'
Rect 'host' 60 180 1020 560 '#FFFFFF' $Border 20
Txt 'host-title' 'HÔTE LXC · 192.168.36.21' 90 198 950 32 23 $Navy $true
Txt 'host-subtitle' "Debian 12 · une carte réseau conservée par l'hôte" 90 238 950 26 16 $Muted
Rect 'host-stack' 100 300 360 185 '#000000' $Border
Txt 'stack-title' "Pile réseau de l'hôte" 120 317 320 30 20 $Navy $true
Txt 'host-ip' '192.168.36.21' 120 355 320 40 27 $Navy $true
Txt 'host-ip-caption' "Adresse propre à l'hôte" 120 412 320 29 16 $Muted
Rect 'container' 650 280 380 235 '#000000' $Blue
Txt 'container-tag' 'CONTENEUR · devodoo14' 675 294 330 27 14 $Blue $true
Txt 'container-title' 'odoo1' 675 327 330 37 28 $Navy $true
Rect 'container-eth0' 675 375 330 58 $Blue 'none' 10
Txt 'container-eth0-label' 'eth0 · 192.168.36.161/24' 686 384 308 40 20 '#FFFFFF' $true 'center'
Txt 'gateway' 'Passerelle : 192.168.36.254' 675 448 330 25 16 $Navy
Txt 'dns' 'DNS : 172.24.10.17 / 172.24.10.18' 675 480 330 23 14 $Muted
Rect 'nic' 360 595 440 95 $Navy 'none' 14
Txt 'nic-title' 'Carte réseau · enp5s0' 380 605 400 32 23 '#FFFFFF' $true 'center'
Txt 'nic-caption' 'Une même MAC sur le LAN' 380 648 400 24 16 '#000000' $false 'center'
Arrow 'stack-to-nic' @(@(280,485),@(280,555),@(470,555),@(470,595)) $Blue $false $true 'host-stack' 'nic'
Arrow 'container-to-nic' @(@(840,515),@(840,555),@(690,555),@(690,595)) $Blue $false $true 'container' 'nic'
Txt 'host-path-label' 'IP hôte' 300 521 170 25 14 $Muted
Txt 'lxc-path-label' 'Interface IPVLAN' 865 521 165 25 14 $Blue
Rect 'lan' 1140 300 400 180 '#FFFFFF' $Blue
Txt 'lan-title' 'LAN APPLICATIONS' 1162 318 356 30 20 $Blue $true
Txt 'lan-subnet' '192.168.36.0/24' 1162 358 356 38 27 $Navy $true
Txt 'lan-gateway' 'Passerelle : 192.168.36.254' 1162 418 356 28 17 $Muted
Arrow 'nic-to-lan' @(@(800,642),@(1110,642),@(1110,390),@(1140,390)) $Blue $false $true 'nic' 'lan'
Rect 'mac-note' 1140 530 400 210 '#000000' '#000000'
Txt 'mac-title' 'Ce que voit le réseau' 1162 548 356 31 20 $Navy $true
Txt 'mac-list' 'IP hôte : 192.168.36.21|IP LXC : 192.168.36.161|Adresse MAC partagée' 1162 590 356 91 18 $Navy
Txt 'mac-remark' 'Les deux IP doivent être autorisées.' 1162 695 356 25 14 '#000000'
Rect 'addressing-note' 60 780 1480 132 '#000000' '#000000'
Txt 'addressing-heading' 'ADRESSAGE DU CONTENEUR' 85 793 1420 24 13 $Teal $true
Txt 'addressing-main' 'IP statique /24 · passerelle .36.254 · DNS configurés dans le conteneur' 85 824 1420 34 22 $Navy $true
Txt 'addressing-detail' "Raccordement direct par IPVLAN. Ce chemin utilise la carte de l'hôte, sans bridge Linux et sans NAT sur l'hôte." 85 871 1420 26 17 $Muted

New-Page '02-acces-utilisateur-odoo' '02 - Accès utilisateur Odoo' '02' 'ACCÈS UTILISATEUR' 'De ton navigateur à Odoo' 'La destination 192.168.36.161:8069 conduit directement au service dans le conteneur.' 'HTTP / 8069'
Rect 'url' 60 170 1480 76 '#000000' '#000000'
Txt 'url-caption' "URL D'ACCÈS" 85 190 175 30 14 $Blue $true
Txt 'url-value' 'http://192.168.36.161:8069' 275 183 1225 45 29 $Blue $true
Rect 'host' 830 290 710 448 '#FFFFFF' $Border 20
Txt 'host-heading' 'HÔTE · 192.168.36.21' 860 309 650 31 21 $Navy $true
Txt 'host-detail' "Linux distribue les paquets selon l'IP de destination." 860 344 650 24 15 $Muted
Rect 'client' 60 390 270 175 '#FFFFFF' $Border
Txt 'client-tag' '01 / POSTE UTILISATEUR' 80 408 230 27 13 $Blue $true
Txt 'client-title' 'Navigateur web' 80 446 230 34 23 $Navy $true
Txt 'client-caption' 'Connexion HTTP vers|192.168.36.161:8069' 80 495 230 49 16 $Muted
Rect 'network' 430 400 280 155 '#000000' '#000000'
Txt 'network-title' 'LAN / réseau routé' 449 418 242 32 20 $Navy $true
Txt 'network-caption' "Poste sur le même LAN|ou disposant d'une route" 449 466 242 58 16 $Muted
Rect 'nic' 865 400 190 160 $Navy 'none'
Txt 'nic-name' 'enp5s0' 880 418 160 36 25 '#FFFFFF' $true 'center'
Txt 'nic-description' 'Carte réseau|de l''hôte' 880 476 160 59 18 '#000000' $false 'center'
Rect 'container' 1115 385 390 290 '#000000' $Blue
Txt 'container-tag' 'CONTENEUR · odoo1' 1140 401 340 27 14 $Blue $true
Txt 'container-ip' '192.168.36.161' 1140 434 340 33 26 $Navy $true
Rect 'eth0' 1140 480 340 54 $Blue 'none' 10
Txt 'eth0-label' 'eth0 · IPVLAN L2' 1150 489 320 35 20 '#FFFFFF' $true 'center'
Rect 'service' 1140 577 340 64 $Teal 'none' 10
Txt 'service-label' 'Odoo 14 · TCP/8069' 1150 589 320 39 22 '#FFFFFF' $true 'center'
Arrow 'http-1' @(@(330,477),@(430,477)) $Blue $false $true 'client' 'network'
Txt 'http-port' 'TCP/8069' 330 435 100 28 13 $Blue $true 'center'
Arrow 'http-2' @(@(710,477),@(865,477)) $Blue $false $true 'network' 'nic'
Txt 'destination-label' 'IP .36.161' 716 434 143 28 13 $Blue $true 'center'
Arrow 'http-3' @(@(1055,507),@(1140,507)) $Blue $false $true 'nic' 'eth0'
Arrow 'http-4' @(@(1310,534),@(1310,577)) $Blue $false $true 'eth0' 'service'
Txt 'ip-dispatch-label' 'IP → LXC' 1057 465 82 26 12 $Blue $true 'center'
Arrow 'http-response' @(@(1310,641),@(1310,703),@(195,703),@(195,565)) $Teal $true $true 'service' 'client'
Rect 'response-label-bg' 380 680 450 36 $Bg 'none' 8
Txt 'response-label' 'Réponse HTTP vers le navigateur' 390 682 430 31 17 $Teal $true 'center'
Rect 'summary-1' 60 785 470 130 '#FFFFFF' $Border
Rect 'summary-2' 565 785 470 130 '#FFFFFF' $Border
Rect 'summary-3' 1070 785 470 130 '#FFFFFF' $Border
Txt 'summary-1-title' '01 / ADRESSE CIBLÉE' 82 799 426 26 14 $Blue $true
Txt 'summary-1-body' 'Le navigateur cible directement|192.168.36.161:8069.' 82 838 426 54 18 $Navy
Txt 'summary-2-title' '02 / DISTRIBUTION PAR LINUX' 587 799 426 26 14 $Blue $true
Txt 'summary-2-body' "IPVLAN remet les paquets pour .36.161|à l'interface eth0 du conteneur." 587 838 426 54 18 $Navy
Txt 'summary-3-title' '03 / SERVICE ODOO' 1092 799 426 26 14 $Teal $true
Txt 'summary-3-body' 'HTTP sur TCP/8069.|Bus / longpolling sur TCP/8072.' 1092 838 426 54 18 $Navy

New-Page '03-flux-odoo-postgresql' '03 - Flux Odoo vers PostgreSQL' '03' 'FLUX INTER-RÉSEAUX' "D'Odoo à PostgreSQL" 'Deux sous-réseaux, une connexion SQL vers le primaire PostgreSQL.' 'SQL / 5432'
Rect 'odoo-lan' 60 170 440 410 '#000000' '#000000' 20
Txt 'odoo-lan-title' 'LAN APPLICATIONS' 85 187 390 28 15 $Blue $true
Txt 'odoo-subnet' '192.168.36.0/24' 85 220 390 35 26 $Navy $true
Rect 'odoo-container' 95 280 370 160 '#FFFFFF' '#000000'
Txt 'odoo-name' 'odoo1 · devodoo14' 115 293 330 30 21 $Navy $true
Txt 'odoo-ip' 'eth0 · 192.168.36.161/24' 115 336 330 30 19 $Blue $true
Txt 'odoo-destination' 'Destination :|192.168.33.161:5432' 115 378 330 47 17 $Muted
Rect 'odoo-nic' 95 480 370 70 $Navy 'none' 12
Txt 'odoo-nic-label' 'enp5s0 · hôte 192.168.36.21' 110 494 340 40 18 '#FFFFFF' $true 'center'
Rect 'db-lan' 1100 170 440 410 '#000000' '#000000' 20
Txt 'db-lan-title' 'LAN BASES DE DONNÉES' 1125 187 390 28 15 $Teal $true
Txt 'db-subnet' '192.168.33.0/24' 1125 220 390 35 26 $Navy $true
Rect 'db-container' 1135 280 370 160 '#FFFFFF' '#000000'
Txt 'db-name' 'odoodb1 · devpg15' 1155 293 330 30 21 $Navy $true
Txt 'db-ip' 'eth0 · 192.168.33.161/24' 1155 336 330 30 19 $Teal $true
Txt 'db-service' 'PostgreSQL 15 · primaire|Écoute TCP/5432' 1155 378 330 47 17 $Muted
Rect 'db-nic' 1135 480 370 70 $Navy 'none' 12
Txt 'db-nic-label' 'enp1s0 · hôte 192.168.33.21' 1150 494 340 40 18 '#FFFFFF' $true 'center'
Rect 'router' 590 320 420 170 $Navy 'none' 18
Txt 'router-title' 'Routage interréseaux' 610 335 380 37 25 '#FFFFFF' $true 'center'
Txt 'router-external' 'Équipement(s) L3 externe(s)' 610 388 380 31 19 '#FFFFFF' $false 'center'
Txt 'router-note' 'Routes et règles à vérifier' 610 441 380 27 17 '#000000' $false 'center'
Txt 'packet' 'SOURCE : 192.168.36.161|DESTINATION : 192.168.33.161:5432' 535 216 530 68 17 $Blue $true 'center'
Arrow 'odoo-to-nic' @(@(280,440),@(280,480)) $Blue $false $true 'odoo-container' 'odoo-nic'
Arrow 'nic-to-router' @(@(465,515),@(550,515),@(550,405),@(590,405)) $Blue $false $true 'odoo-nic' 'router'
Arrow 'router-to-db-nic' @(@(1010,405),@(1050,405),@(1050,515),@(1135,515)) $Blue $false $true 'router' 'db-nic'
Arrow 'db-nic-to-container' @(@(1320,480),@(1320,440)) $Blue $false $true 'db-nic' 'db-container'
Txt 'ipvlan-left' 'IPVLAN' 303 446 145 27 13 $Blue
Txt 'ipvlan-right' 'IPVLAN' 1343 446 145 27 13 $Blue
Arrow 'sql-response' @(@(1135,355),@(1080,355),@(1080,603),@(520,603),@(520,355),@(465,355)) $Teal $true $true 'db-container' 'odoo-container'
Rect 'response-bg' 590 582 420 40 $Bg 'none' 6
Txt 'response-text' 'Réponses SQL / route retour' 600 585 400 32 17 $Teal $true 'center'
Rect 'gateway-odoo' 60 625 440 80 '#FFFFFF' $Border
Txt 'gateway-odoo-title' 'PASSERELLE DU CONTENEUR ODOO' 80 632 400 25 13 $Blue $true
Txt 'gateway-odoo-ip' '192.168.36.254' 80 662 400 32 24 $Navy $true
Rect 'gateway-db' 1100 625 440 80 '#FFFFFF' $Border
Txt 'gateway-db-title' 'PASSERELLE DU CONTENEUR POSTGRESQL' 1120 632 400 25 13 $Teal $true
Txt 'gateway-db-ip' '192.168.33.254' 1120 662 400 32 24 $Navy $true
Txt 'gateway-scope' "Passerelles déclarées dans host_vars.|Leur implantation physique est externe au dépôt." 535 645 530 51 16 $Muted $false 'center'
Rect 'conditions' 60 755 1480 160 '#FFFFFF' $Border
Txt 'conditions-title' 'CONDITIONS DE FONCTIONNEMENT' 85 770 1420 27 14 $Blue $true
Txt 'conditions-body' 'Routage aller / retour entre les deux sous-réseaux et autorisation TCP/5432.|PostgreSQL : écoute sur .33.161 et autorisation des clients Odoo dans pg_hba.conf.|NAT désactivé sur les hôtes. La source reste .36.161 jusqu''à PostgreSQL si le réseau externe ne fait aucun SNAT.' 85 810 1420 85 18 $Navy


# Habillage monochrome et pictogrammes vectoriels, communs aux trois exports.
function Find-Item($id) {
 $found=$script:Page.Items | Where-Object { $_.Id -eq $id } | Select-Object -First 1
 if(!$found) { throw "Élément de mise en page absent : $id" }
 return $found
}
function Place-Text($id,$x,$y,$w,$h) {
 $item=Find-Item $id
 $item.X=$x; $item.Y=$y; $item.W=$w; $item.H=$h
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

foreach($currentPage in $Pages) {
 $script:Page=$currentPage
 $existingItems=@($script:Page.Items)
 $script:Page.Items=[System.Collections.Generic.List[object]]::new()
 Rect 'background' 0 0 1600 1000 '#FFFFFF' 'none' 0
 # La grille native seule est omise par les exports draw.io : celle-ci est dessinée et verrouillée.
 for($gx=20;$gx -lt 1600;$gx+=20) {
  $gridWeight=if($gx%100 -eq 0){0.35}else{0.18}
  Arrow ('grid-v-'+$gx) @(@($gx,0),@($gx,1000)) '#000000' $false $false '' '' $gridWeight $true
 }
 for($gy=20;$gy -lt 1000;$gy+=20) {
  $gridWeight=if($gy%100 -eq 0){0.35}else{0.18}
  Arrow ('grid-h-'+$gy) @(@(0,$gy),@(1600,$gy)) '#000000' $false $false '' '' $gridWeight $true
 }
 foreach($item in $existingItems) {
  if($item.Id -eq 'background') { continue }
  switch($item.Kind) {
   'rect' {
    $item.Fill='#FFFFFF'; $item.Stroke='#000000'; $item.Radius=0
    if($item.Id -in @('header','response-label-bg','response-bg')) { $item.Stroke='none' }
   }
   'text' { $item.Color='#000000' }
   'line' { $item.Color='#000000' }
  }
  [void]$script:Page.Items.Add($item)
 }
 Arrow 'header-rule' @(@(0,138),@(1600,138)) '#000000' $false $false '' '' 1
 Rect 'legend-background' 945 142 595 24 '#FFFFFF' 'none' 0
 Arrow 'legend-request' @(@(960,154),@(1000,154)) '#000000' $false $true
 Txt 'legend-request-text' 'Liaison / requête' 1013 143 205 23 13 '#000000'
 Arrow 'legend-response' @(@(1250,154),@(1290,154)) '#000000' $true $true
 Txt 'legend-response-text' 'Réponse' 1303 143 210 23 13 '#000000'

 switch($currentPage.Slug) {
  '01-raccordement-ipvlan' {
   Icon 'icon-host' 'server' 90 197 52
   Place-Text 'host-title' 160 198 880 32
   Place-Text 'host-subtitle' 160 238 880 26
   Icon 'icon-stack' 'network' 120 312 40
   Place-Text 'stack-title' 175 317 265 30
   Icon 'icon-container' 'container' 675 292 50
   Place-Text 'container-tag' 740 294 265 27
   Place-Text 'container-title' 740 327 265 37
   Icon 'icon-nic' 'nic' 380 615 48
   Place-Text 'nic-title' 445 605 335 32
   Place-Text 'nic-caption' 445 648 335 24
   Icon 'icon-lan' 'network' 1162 316 48
   Place-Text 'lan-title' 1228 318 290 30
   Place-Text 'lan-subnet' 1162 376 356 38
   Place-Text 'lan-gateway' 1162 430 356 28
  }
  '02-acces-utilisateur-odoo' {
   Icon 'icon-host' 'server' 860 307 50
   Place-Text 'host-heading' 925 309 580 31
   Place-Text 'host-detail' 925 344 580 24
   Icon 'icon-client' 'browser' 80 410 50
   Place-Text 'client-tag' 145 408 165 27
   (Find-Item 'client-tag').Text='UTILISATEUR'
   Place-Text 'client-title' 145 446 165 34
   (Find-Item 'client-title').Text='Navigateur'
   Icon 'icon-network' 'network' 449 416 44
   Place-Text 'network-title' 507 418 184 32
   (Find-Item 'network-title').Text='Réseau LAN'
   Icon 'icon-nic' 'nic' 937 407 46
   Place-Text 'nic-name' 880 455 160 34
   Place-Text 'nic-description' 880 499 160 53
   Icon 'icon-container' 'container' 1140 399 50
   Place-Text 'container-tag' 1205 401 275 27
   Place-Text 'container-ip' 1205 434 275 33
   Icon 'icon-odoo' 'browser' 1152 584 49
   Place-Text 'service-label' 1210 589 260 39
  }
  '03-flux-odoo-postgresql' {
   Icon 'icon-odoo' 'container' 115 292 48
   Place-Text 'odoo-name' 180 293 265 30
   Icon 'icon-database' 'database' 1155 292 48
   Place-Text 'db-name' 1220 293 265 30
   Icon 'icon-odoo-nic' 'nic' 110 492 42
   Place-Text 'odoo-nic-label' 165 494 285 40
   Icon 'icon-db-nic' 'nic' 1150 492 42
   Place-Text 'db-nic-label' 1205 494 285 40
   Icon 'icon-router' 'router' 615 335 64
   Place-Text 'router-title' 700 338 290 37
   Place-Text 'router-external' 610 409 380 31
   Place-Text 'router-note' 610 448 380 27
   Icon 'icon-gateway-odoo' 'router' 78 642 45
   Place-Text 'gateway-odoo-title' 138 632 342 25
   Place-Text 'gateway-odoo-ip' 138 662 342 32
   Icon 'icon-gateway-db' 'router' 1118 642 45
   Place-Text 'gateway-db-title' 1178 632 342 25
   Place-Text 'gateway-db-ip' 1178 662 342 32
  }
 }
}

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
 [void]$svg.AppendLine(('<title id="title">'+(Esc $page.Name)+'</title><desc id="desc">Schéma réseau LXC. Configuration du dépôt du 18 octobre 2026, serveurs non audités.</desc>'))
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
$drawio=Join-Path $OutputDirectory 'architecture-lxc-professionnelle.drawio'
$document.Save($drawio)
$parsed=[xml][System.IO.File]::ReadAllText($drawio)
if($parsed.SelectNodes('//diagram').Count -ne 3) { throw 'Le document doit contenir trois pages.' }
if($Warnings.Count -gt 0) { throw ('Débordements typographiques : '+($Warnings -join ' ; ')) }

$readme=@'
# Schémas réseau LXC

Les trois vues décrivent la configuration du dépôt au 18 octobre 2026. Elles ne constituent pas un contrôle des serveurs.

Ouvrir **architecture-lxc-professionnelle.drawio** avec draw.io / diagrams.net ou l'extension Draw.io de VS Code. Le fichier contient trois onglets en noir et blanc, avec quadrillage visible. Les formes, icônes vectorielles, textes et connecteurs sont modifiables.

| Vue | Aperçu | Format vectoriel |
| --- | --- | --- |
| Raccordement IPVLAN L2 | [PNG](01-raccordement-ipvlan.png) | [SVG](01-raccordement-ipvlan.svg) |
| Accès utilisateur à Odoo | [PNG](02-acces-utilisateur-odoo.png) | [SVG](02-acces-utilisateur-odoo.svg) |
| Flux Odoo vers PostgreSQL | [PNG](03-flux-odoo-postgresql.png) | [SVG](03-flux-odoo-postgresql.svg) |

![Raccordement IPVLAN](01-raccordement-ipvlan.png)

![Accès utilisateur Odoo](02-acces-utilisateur-odoo.png)

![Flux Odoo vers PostgreSQL](03-flux-odoo-postgresql.png)

## Lire les schémas

- Trait noir plein : raccordement ou requête vers le service.
- Trait noir pointillé : réponse vers le client.
- Quadrillage de 20 unités : visible dans draw.io et dans les exports, placé au fond et verrouillé.
- Icônes vectorielles : serveur en rack, conteneur, navigateur, réseau, carte réseau, routeur et base PostgreSQL.
- Contours des hôtes et conteneurs : limites logiques d'exécution.
- Les équipements de routage externes sont représentés sans inventer de switch, de VLAN ou de routeur physique.
- Les adresses MAC ne sont pas inventées : le conteneur partage celle de la carte parente.
- Le chemin représenté utilise IPVLAN L2. Un ancien lxcbr0 peut exister sur l'hôte, en dehors de ce chemin.

Le rôle ne permet pas une communication directe hôte / propre conteneur via l'interface IPVLAN parente. Faire les contrôles d'accès depuis un autre poste disposant de la route, ou utiliser lxc-attach sur l'hôte.

## Sources dans le dépôt

- [inventory.yaml](../../inventory.yaml) : lxc_net_type=ipvlan, lxc_egress_nat=false.
- [host_vars/192.168.36.21.yml](../../host_vars/192.168.36.21.yml) : carte, IP, passerelle et DNS d'odoo1.
- [host_vars/192.168.33.21.yml](../../host_vars/192.168.33.21.yml) : paramètres d'odoodb1.
- [roles/lxc_lan/defaults/main.yml](../../roles/lxc_lan/defaults/main.yml) : mode IPVLAN l2.
- [roles/lxc_lan/tasks/main.yaml](../../roles/lxc_lan/tasks/main.yaml) : configuration LXC et systemd-networkd.
- [group_vars/all/vars.yml](../../group_vars/all/vars.yml) : cible PostgreSQL et ports Odoo.

Le routage aller et retour, les autorisations TCP/5432 et l'éventuel SNAT dans le réseau externe doivent être vérifiés sur l'infrastructure.

## Régénérer les fichiers

Depuis PowerShell sous Windows : .\generer-schemas.ps1

Le script utilise uniquement XML, SVG et System.Drawing. Il génère le document draw.io, les SVG et les PNG 3200 × 2000 et vérifie les identifiants, les limites de page et la largeur des textes. Les modifications faites directement dans draw.io ne sont pas réimportées dans ce script.
'@
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.md'),$readme,[System.Text.UTF8Encoding]::new($false))
Write-Output 'Validation : 3 pages draw.io ; 3 SVG valides ; 3 PNG 3200 x 2000 ; aucun débordement de texte ; palette noir/blanc et grille visible.'
Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name,Length
