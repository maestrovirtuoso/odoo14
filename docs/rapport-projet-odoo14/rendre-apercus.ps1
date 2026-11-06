param([string]$PdfPath=(Join-Path $PSScriptRoot 'Rapport-ProSys-Odoo14-Architecture-Fonctionnement.pdf'),[string]$OutputDirectory=(Join-Path $PSScriptRoot 'apercus'),[int]$Width=1100)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
$pdfType=[Windows.Data.Pdf.PdfDocument,Windows.Data,ContentType=WindowsRuntime]
$optionsType=[Windows.Data.Pdf.PdfPageRenderOptions,Windows.Data,ContentType=WindowsRuntime]
$asOperation=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*'}
$asAction=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and !($_.IsGenericMethodDefinition) -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'}
$loadMethod=$asOperation.MakeGenericMethod([type[]]@($pdfType))
$sourceStream=[IO.File]::OpenRead([IO.Path]::GetFullPath($PdfPath))
$sourceRandom=[IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($sourceStream)
try{
 $operation=[Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($sourceRandom)
 $task=$loadMethod.Invoke($null,[object[]]@($operation))
 $pdf=$task.GetAwaiter().GetResult()
 [void][IO.Directory]::CreateDirectory($OutputDirectory)
 $rendered=@()
 for($number=1;$number -le $pdf.PageCount;$number++){
  $page=$pdf.GetPage([uint32]($number-1))
  $memory=[IO.MemoryStream]::new()
  $random=[IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
  try{
   $options=[Activator]::CreateInstance($optionsType)
   $options.DestinationWidth=[uint32]$Width
   $options.DestinationHeight=[uint32][Math]::Round($Width*$page.Size.Height/$page.Size.Width)
   $operation=$page.RenderToStreamAsync($random,$options)
   $task=$asAction.Invoke($null,[object[]]@($operation))
   $null=$task.GetAwaiter().GetResult()
   $path=Join-Path $OutputDirectory ('page-{0:000}.png' -f $number)
   [IO.File]::WriteAllBytes($path,$memory.ToArray())
   $rendered+=,[pscustomobject]@{number=$number;path=$path;width=$options.DestinationWidth;height=$options.DestinationHeight}
  }finally{$random.Dispose();$memory.Dispose();$page.Dispose()}
 }
 $labelFont=[Drawing.Font]::new('Segoe UI',15,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
 for($start=0;$start -lt $rendered.Count;$start+=20){
  $sheet=[Drawing.Bitmap]::new(1410,1490)
  $g=[Drawing.Graphics]::FromImage($sheet)
  $g.Clear([Drawing.Color]::White)
  $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.DrawString(('RAPPORT PROSYS - PAGES '+($start+1)+' A '+[Math]::Min($start+20,$rendered.Count)),$labelFont,[Drawing.Brushes]::Black,25,15)
  for($i=$start;$i -lt [Math]::Min($start+20,$rendered.Count);$i++){
   $local=$i-$start;$x=25+($local%5)*276;$y=60+[Math]::Floor($local/5)*350
   $item=$rendered[$i];$image=[Drawing.Image]::FromFile($item.path)
   $scale=[Math]::Min(260.0/$image.Width,310.0/$image.Height)
   $w=$image.Width*$scale;$h=$image.Height*$scale
   $g.DrawImage($image,[Drawing.RectangleF]::new(($x+(260-$w)/2),$y,$w,$h))
   $g.DrawRectangle([Drawing.Pens]::Black,[single]($x+(260-$w)/2),[single]$y,[single]$w,[single]$h)
   $image.Dispose()
   $g.DrawString(('Page '+($i+1)),$labelFont,[Drawing.Brushes]::Black,$x,$y+315)
  }
  $sheet.Save((Join-Path $OutputDirectory ('planche-{0:00}.png' -f (1+[Math]::Floor($start/20)))),[Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose();$sheet.Dispose()
 }
 $labelFont.Dispose()
 Write-Output ('Rendu visuel : '+$pdf.PageCount+' pages PNG et '+[Math]::Ceiling($pdf.PageCount/20)+' planches.')
}finally{$sourceRandom.Dispose();$sourceStream.Dispose()}
