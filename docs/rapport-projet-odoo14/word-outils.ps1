
function End-Range { $script:Doc.Range($script:Doc.Content.End-1,$script:Doc.Content.End-1) }
function Add-Paragraph($text,$style=-1,$size=11,$bold=$false,$color=0) {
 $start=$script:Doc.Content.End-1
 $r=End-Range
 $normalized=([string]$text).Replace(([string][char]13+[char]10),[string][char]10).Replace([string][char]10,[string][char]13)
 $r.InsertAfter($normalized+[char]13)
 $r=$script:Doc.Range($start,$script:Doc.Content.End-1)
 $r.Style=$script:Doc.Styles.Item([int]$style).NameLocal
 $r.Font.Name='Calibri';$r.Font.Size=[single]$size
 $r.Font.Underline=0;$r.Shading.BackgroundPatternColor=16777215
 $r.ParagraphFormat.Alignment=0;$r.ParagraphFormat.LeftIndent=0;$r.ParagraphFormat.FirstLineIndent=0;$r.ParagraphFormat.LineSpacingRule=0
 $r.Font.Bold=[int][bool]$bold;$r.Font.Color=[int]$color
 $r.ParagraphFormat.SpaceBefore=0;$r.ParagraphFormat.SpaceAfter=6
 $r.ParagraphFormat.KeepTogether=-1
 $r.ParagraphFormat.KeepWithNext=if($style -in @(-2,-3)){-1}else{0}
 $script:LastParagraph=$r
}
function Add-Table($headers,$rows) {
 Add-Paragraph '' -1 2
 $table=$script:Doc.Tables.Add((End-Range),($rows.Count+1),$headers.Count)
 $table.Range.Style=$script:Doc.Styles.Item(-1).NameLocal
 $table.Borders.Enable=1
 $table.Range.Font.Name='Calibri';$table.Range.Font.Size=10
 $table.Range.ParagraphFormat.SpaceBefore=2;$table.Range.ParagraphFormat.SpaceAfter=3
 $table.Range.ParagraphFormat.KeepWithNext=0
 $table.TopPadding=4;$table.BottomPadding=4
 $table.Rows.AllowBreakAcrossPages=0
 for($col=0;$col -lt $headers.Count;$col++){$table.Cell(1,$col+1).Range.Text=[string]$headers[$col]}
 for($row=0;$row -lt $rows.Count;$row++){
  for($col=0;$col -lt $headers.Count;$col++){$table.Cell($row+2,$col+1).Range.Text=[string]$rows[$row][$col]}
 }
 $table.Rows.Item(1).HeadingFormat=-1
 $table.Rows.Item(1).Range.Font.Bold=1
 $table.Rows.Item(1).Shading.BackgroundPatternColor=0xEAEAEA
 $table.AutoFitBehavior(2)
 $table.Range.InsertParagraphAfter()
}
function Add-Picture($relativePath,$maxWidth,$maxHeight) {
 $path=if([IO.Path]::GetFileName($relativePath) -eq 'architecture-reseau-lxc-historique.png'){Join-Path $OutputDirectory 'architecture-reseau-lxc-historique.png'}else{[IO.Path]::GetFullPath((Join-Path $ProjectRoot $relativePath))}
 if(!(Test-Path -LiteralPath $path)){throw "Image absente : $relativePath"}
 $image=[Drawing.Image]::FromFile($path)
 try{$width=$image.Width;$height=$image.Height}finally{$image.Dispose()}
 $scale=[Math]::Min($maxWidth/$width,$maxHeight/$height)
 $inline=$script:Doc.InlineShapes.AddPicture($path,$false,$true,(End-Range))
 $inline.LockAspectRatio=-1;$inline.Width=[single]($width*$scale)
 $inline.AlternativeText=$relativePath
 $inline.Range.ParagraphFormat.Alignment=1
 $inline.Range.ParagraphFormat.SpaceBefore=0;$inline.Range.ParagraphFormat.SpaceAfter=5
 $inline.Range.ParagraphFormat.KeepWithNext=0
 $after=$script:Doc.Range($inline.Range.End,$inline.Range.End);$after.InsertAfter([string][char]13)
 $script:LastPicture=$inline
}
function Set-PageLayout($section,$layout) {
 $setup=$section.PageSetup
 switch($layout){
  'a3landscape' {$setup.Orientation=1;$setup.PageWidth=1190.55;$setup.PageHeight=841.89}
  'a3portrait' {$setup.Orientation=0;$setup.PageWidth=841.89;$setup.PageHeight=1190.55}
  'a4landscape' {$setup.Orientation=1;$setup.PageWidth=841.89;$setup.PageHeight=595.28}
  default {$setup.Orientation=0;$setup.PageWidth=595.28;$setup.PageHeight=841.89}
 }
 $setup.TopMargin=36;$setup.BottomMargin=36
 $setup.LeftMargin=42;$setup.RightMargin=42
 $setup.HeaderDistance=15;$setup.FooterDistance=15
}
function Next-ReportPage($layout='a4portrait') {
 $r=End-Range
 if($layout -ne $script:CurrentLayout){
  $r.InsertBreak(2)
  $section=$script:Doc.Sections.Item($script:Doc.Sections.Count)
  Set-PageLayout $section $layout
  $section.PageSetup.DifferentFirstPageHeaderFooter=0
  $script:CurrentLayout=$layout
 } else {$r.InsertBreak(7)}
}
function Add-Block($block){
 switch($block.type){
  'h2' {Add-Paragraph $block.text -3 14 $true 0x554433}
  'p' {Add-Paragraph $block.text}
  'bullet' {
   Add-Paragraph ('• '+$block.text)
   $script:LastParagraph.ParagraphFormat.LeftIndent=12
   $script:LastParagraph.ParagraphFormat.FirstLineIndent=-9
  }
  'code' {
   Add-Paragraph $block.text -1 9.5
   $script:LastParagraph.Font.Name='Consolas'
   $script:LastParagraph.Shading.BackgroundPatternColor=0xF2F2F2
  }
  'source' {Add-Paragraph $block.text -1 8.5 $false 0x666666}
  'table' {Add-Table $block.headers $block.rows}
  'link' {
   Add-Paragraph $block.label -1 10
   $anchor=$script:LastParagraph.Duplicate
   $anchor.MoveEnd(1,-1) | Out-Null
   $null=$script:Doc.Hyperlinks.Add($anchor,[string]$block.url)
  }
  default {throw "Bloc inconnu : $($block.type)"}
 }
}
function Ascii-Extract($source,$index,$mode='',$marker=''){
 $path=Join-Path $ProjectRoot $source
 $raw=Get-Content -LiteralPath $path -Raw -Encoding UTF8
 if($mode -eq 'comment_contains'){
  $lines=$raw.Replace([string][char]13,'').Split([char]10)
  $start=-1
  for($i=0;$i -lt $lines.Count;$i++){if($lines[$i].Contains($marker)){$start=$i;break}}
  if($start -lt 0){throw "Commentaire absent : $source / $marker"}
  $output=[Collections.Generic.List[string]]::new()
  for($i=$start;$i -lt $lines.Count;$i++){
   if($lines[$i].Trim() -eq '#' -or $lines[$i] -notmatch '^#'){break}
   [void]$output.Add(($lines[$i] -replace '^# ?',''))
  }
  return ($output -join [string][char]10)
 }
 $fence=[string]::new([char]96,3)
 $pattern='(?ms)^'+[regex]::Escape($fence)+'[^\r\n]*\r?\n(.*?)^'+[regex]::Escape($fence)
 $all=@()
 foreach($match in [regex]::Matches($raw,$pattern)){
  $body=$match.Groups[1].Value.TrimEnd()
  if($mode -eq 'fence_contains' -and $body.Contains($marker)){return $body}
  if($body -match '[┌└]'){$all+=,$body}
 }
 if($mode -eq 'fence_contains'){throw "Schema textuel absent : $source / $marker"}
 if($index -lt 1 -or $index -gt $all.Count){throw "Schema textuel absent : $source / $index"}
 return $all[$index-1]
}
