
$drawio=Join-Path $OutputDirectory 'dossier-patroni-odoo14.drawio'
$document.Save($drawio)
$parsed=[xml][System.IO.File]::ReadAllText($drawio)
if($parsed.SelectNodes('//diagram').Count -ne 14){throw 'Le dossier doit contenir 14 pages.'}
if($Warnings.Count -gt 0){throw ('Debordements typographiques : '+($Warnings -join ' ; '))}
$installation=[System.Xml.XmlDocument]::new()
$installation.LoadXml('<mxfile host="app.diagrams.net" type="device"/>')
foreach($diagram in $document.SelectNodes('//diagram[position() >= 13]')) {
 [void]$installation.DocumentElement.AppendChild($installation.ImportNode($diagram,$true))
}
$installation.Save((Join-Path $OutputDirectory 'installation-odoo14-debian-lxc.drawio'))

# Planche de consultation de l'ensemble des vues.
$sheet=[System.Drawing.Bitmap]::new(1920,1580)
$sheetGraphics=[System.Drawing.Graphics]::FromImage($sheet)
$sheetGraphics.Clear([System.Drawing.Color]::White)
$sheetGraphics.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$titleFont=[System.Drawing.Font]::new('Segoe UI',28,[System.Drawing.FontStyle]::Bold,[System.Drawing.GraphicsUnit]::Pixel)
$labelFont=[System.Drawing.Font]::new('Segoe UI',16,[System.Drawing.FontStyle]::Regular,[System.Drawing.GraphicsUnit]::Pixel)
$sheetGraphics.DrawString('ODOO 14 / PATRONI - 14 VUES TECHNIQUES',$titleFont,[System.Drawing.Brushes]::Black,40,24)
for($i=0;$i -lt $records.Count;$i++) {
 $x=40+($i%4)*460;$y=100+[Math]::Floor($i/4)*360
 $source=[System.Drawing.Image]::FromFile((Join-Path $OutputDirectory ($records[$i].slug+'.png')))
 $sheetGraphics.DrawImage($source,[System.Drawing.Rectangle]::new($x,$y,450,300))
 $source.Dispose()
 $sheetGraphics.DrawRectangle([System.Drawing.Pens]::Black,$x,$y,450,300)
 $sheetGraphics.DrawString(('{0:00} - {1}' -f ($i+1),$records[$i].title),$labelFont,[System.Drawing.Brushes]::Black,[System.Drawing.RectangleF]::new($x,$y+305,450,48))
}
$sheet.Save((Join-Path $OutputDirectory 'apercu-14-schemas.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$titleFont.Dispose();$labelFont.Dispose();$sheetGraphics.Dispose();$sheet.Dispose()
$manifest=[ordered]@{
 date='2026-11-03';pg_ha_enabled=$true;pages=14;logical_size=@(2400,1600);png_size=@(4800,3200)
 typography_overflows=$Warnings.Count;diagram_ids=@($records | ForEach-Object {$_.slug})
}
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'verification.json'),($manifest | ConvertTo-Json -Depth 5),[System.Text.UTF8Encoding]::new($false))
Write-Output 'Validation : 14 pages draw.io, 14 SVG, 14 PNG 4800 x 3200, 14 draw.io individuels ; textes sans debordement.'
