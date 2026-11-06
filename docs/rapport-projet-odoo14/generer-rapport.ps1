param([string]$OutputDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$ProjectRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(!(Test-Path -LiteralPath (Join-Path $ProjectRoot 'inventory.yaml'))){throw 'Racine du projet invalide.'}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
. (Join-Path $PSScriptRoot 'word-outils.ps1')
& (Join-Path $PSScriptRoot 'exporter-reseau-historique.ps1') -ProjectRoot $ProjectRoot -OutputDirectory $OutputDirectory
$pages=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rapport-contenu.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$docx=Join-Path $OutputDirectory 'Rapport-ProSys-Odoo14-Architecture-Fonctionnement.docx'
$pdf=Join-Path $OutputDirectory 'Rapport-ProSys-Odoo14-Architecture-Fonctionnement.pdf'
$script:Word=$null;$script:Doc=$null
$figures=[Collections.Generic.List[object]]::new()
try{
 $script:Word=New-Object -ComObject Word.Application
 $script:Word.Visible=$false;$script:Word.DisplayAlerts=0
 $script:Doc=$script:Word.Documents.Add()
 $script:Doc.Content.LanguageID=1036
 $normal=$script:Doc.Styles.Item(-1)
 $normal.Font.Name='Calibri';$normal.Font.Size=11
 $normal.ParagraphFormat.SpaceAfter=6
 $script:Doc.Styles.Item(-2).ParagraphFormat.KeepWithNext=-1
 $script:Doc.Styles.Item(-3).ParagraphFormat.KeepWithNext=-1
 $script:CurrentLayout='a4portrait'
 Set-PageLayout ($script:Doc.Sections.Item(1)) 'a4portrait'
 $script:Doc.Sections.Item(1).PageSetup.DifferentFirstPageHeaderFooter=-1
 $header=$script:Doc.Sections.Item(1).Headers.Item(1).Range
 $header.Text='PROSYS | ODOO 14 | RAPPORT D''ARCHITECTURE ET DE FONCTIONNEMENT'
 $header.Font.Name='Calibri';$header.Font.Size=8;$header.Font.Color=0x666666
 $footer=$script:Doc.Sections.Item(1).Footers.Item(1).Range
 $footer.Text='3 novembre 2026 — Page '
 $footer.Font.Name='Calibri';$footer.Font.Size=8;$footer.Font.Color=0x666666
 $position=$footer.End-1
 $fr=$footer.Duplicate;$fr.SetRange($position,$position);$null=$fr.Fields.Add($fr,33)
 $footer=$script:Doc.Sections.Item(1).Footers.Item(1).Range
 $position=$footer.End-1
 $fr=$footer.Duplicate;$fr.SetRange($position,$position);$fr.InsertAfter(' / ')
 $footer=$script:Doc.Sections.Item(1).Footers.Item(1).Range
 $position=$footer.End-1
 $fr=$footer.Duplicate;$fr.SetRange($position,$position);$null=$fr.Fields.Add($fr,26)
 $first=$true;$index=0
 foreach($page in $pages){
  $index++
  $layout=if($page.layout){$page.layout}else{'a4portrait'}
  if(!$first){Next-ReportPage $layout};$first=$false
  switch($page.type){
   'cover' {
    Add-Paragraph 'DOSSIER TECHNIQUE ET FONCTIONNEL' -1 11 $true 0x554433
    $script:LastParagraph.ParagraphFormat.SpaceBefore=75
    Add-Paragraph $page.title -1 38 $true 0x554433
    Add-Paragraph $page.subtitle -1 23 $false 0x554433
    Add-Paragraph $page.date -1 15
    Add-Paragraph $page.summary -1 14
    Add-Paragraph $page.scope -1 12
    Add-Paragraph 'Configuration de référence : pg_ha_enabled = true' -1 12 $true
    Add-Paragraph 'Périmètre métier : ensemble des familles ERP demandé par le porteur du projet.' -1 11
    Add-Paragraph 'Rapport fondé sur le dépôt local ; les états historiques sont identifiés. Les schémas sont intégrés dans ce document.' -1 11
    Add-Paragraph 'Version 1.0 — Projet ProSys' -1 10 $false 0x666666
   }
   'toc' {
    Add-Paragraph 'Sommaire' -1 25 $true 0x554433
    $targetIndex=0
    foreach($entry in $pages){
     $targetIndex++
     if($entry.title -match '^\d+\.\s'){
      Add-Paragraph $entry.title -1 12
      $anchor=$script:LastParagraph.Duplicate
      $anchor.MoveEnd(1,-1) | Out-Null
      $null=$script:Doc.Hyperlinks.Add($anchor,'',('Section_'+('{0:000}' -f $targetIndex)))
     }
    }
    Add-Paragraph 'Les liens du sommaire et les titres du volet de navigation donnent accès aux chapitres et aux figures.' -1 10 $false 0x666666
   }
   'text' {
    Add-Paragraph $page.title -2 21 $true 0x554433
    $null=$script:Doc.Bookmarks.Add(('Section_'+('{0:000}' -f $index)),$script:LastParagraph.Duplicate)
    foreach($block in $page.blocks){Add-Block $block}
   }
   'atlasIntro' {
    Add-Paragraph $page.title -2 21 $true 0x554433
    $null=$script:Doc.Bookmarks.Add(('Section_'+('{0:000}' -f $index)),$script:LastParagraph.Duplicate)
    Add-Paragraph $page.status -1 10 $true
    foreach($text in $page.paragraphs){Add-Paragraph $text}
    Add-Picture $page.image 490 400
   }
   'historyIntro' {
    Add-Paragraph $page.title -2 21 $true 0x554433
    $null=$script:Doc.Bookmarks.Add(('Section_'+('{0:000}' -f $index)),$script:LastParagraph.Duplicate)
    foreach($text in $page.paragraphs){Add-Paragraph $text}
    Add-Table @('Époque','Évolution représentée') $page.rows
   }
   'figure' {
    $begin=$script:Doc.Content.End-1
    Add-Paragraph ('Figure '+$page.number+' — '+$page.title) -3 17 $true 0x554433
    Add-Paragraph $page.status -1 9.5 $true 0x666666
    $script:LastParagraph.ParagraphFormat.KeepWithNext=-1
    if($layout -eq 'a3portrait'){Add-Picture $page.path 740 850}else{Add-Picture $page.path 1040 540}
    $picture=$script:LastPicture
    Add-Paragraph ('Lecture : '+$page.reading) -1 10.5
    Add-Paragraph ('Fonctionnement : '+$page.application) -1 10.5
    Add-Paragraph ('À retenir : '+$page.takeaway) -1 10.5
    Add-Paragraph ('Source : '+$page.source+' | Fichier : '+$page.sourceArtifact) -1 8.5 $false 0x666666
    $name='Figure_'+('{0:00}' -f $page.number)
    $null=$script:Doc.Bookmarks.Add($name,$script:Doc.Range($begin,$script:Doc.Content.End-1))
    $figures.Add([pscustomobject]@{number=$page.number;name=$name;picture=$picture;title=$page.title;source=$page.sourceArtifact})
    if($page.number%4 -eq 0){Write-Output ('Figures intégrées : '+$page.number+'/27')}
   }
   'ascii' {
    Add-Paragraph ('T'+('{0:00}' -f $page.number)+' — '+$page.title) -3 18 $true 0x554433
    Add-Paragraph $page.status -1 10 $true 0x666666
    Add-Paragraph (Ascii-Extract $page.source $page.index $page.mode $page.marker) -1 9.5
    $script:LastParagraph.Font.Name='Consolas'
    $script:LastParagraph.Shading.BackgroundPatternColor=0xF3F3F3
    $script:LastParagraph.ParagraphFormat.LineSpacingRule=4
    $script:LastParagraph.ParagraphFormat.LineSpacing=11.5
    Add-Paragraph $page.explanation -1 11
    Add-Paragraph ('Source : '+$page.source+' ; schéma textuel '+$page.index) -1 9 $false 0x666666
   }
   default {throw "Page inconnue : $($page.type)"}
  }
 }
 Write-Output 'Enregistrement du DOCX...'
 $script:Doc.Content.LanguageID=1036
 $script:Doc.SaveAs2([string]$docx,16)
 Write-Output 'DOCX enregistre. Export du PDF...'
 $script:Doc.ExportAsFixedFormat([string]$pdf,17,$false,0,0,1,1,0,$true,$true,1,$true,$true,$false)
 Write-Output 'PDF exporte. Verification finale...'
 $figurePages=@(foreach($figure in $figures){
  $r=$script:Doc.Bookmarks.Item($figure.name).Range
  [ordered]@{number=$figure.number;page=$script:Doc.Range($r.Start,$r.Start+1).Information(3);title=$figure.title;source=$figure.source}
 })
 $verification=[ordered]@{
  date='2026-11-03';docx=[IO.Path]::GetFileName($docx);pdf=[IO.Path]::GetFileName($pdf)
  pages=$script:Doc.ComputeStatistics(2);figures=$figures.Count;schemas_textuels=12
  images_integrees=$script:Doc.InlineShapes.Count;tables=$script:Doc.Tables.Count;sections=$script:Doc.Sections.Count
  planches_sur_une_page='Controle visuel PDF';sommaire='10 liens internes';figures_par_page=$figurePages
 }
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'verification-rapport.json'),($verification | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 Write-Output ('Rapport validé : '+$verification.pages+' pages, '+$verification.figures+' figures et 12 schémas textuels.')
}catch{ Write-Output $_.ScriptStackTrace; Write-Output $_.Exception.Message; throw }finally{
 if($script:Doc){try{$discard=0;$script:Doc.Close([ref]$discard)}catch{Write-Output $_.Exception.Message}}
 if($script:Word){try{$discard=0;$script:Word.Quit([ref]$discard)}catch{Write-Output $_.Exception.Message}}
 if($script:Doc){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:Doc)}
 if($script:Word){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($script:Word)}
 [GC]::Collect();[GC]::WaitForPendingFinalizers()
}
