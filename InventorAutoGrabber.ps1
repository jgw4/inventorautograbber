param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [ValidateRange(1, 20000)]
    [int]$OutputWidth = 2400,

    [ValidateRange(1, 20000)]
    [int]$OutputHeight = 2400,

    [ValidateSet("png", "jpg", "bmp", "gif", "tif")]
    [string]$OutputFileType = "png",

    [string]$Background = "White",

    [switch]$Recurse,

    [switch]$UseRunningInventor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

function Get-InventorApplication {
    param(
        [switch]$UseRunningInventor
    )

    if ($UseRunningInventor) {
        try {
            return [Runtime.InteropServices.Marshal]::GetActiveObject("Inventor.Application")
        }
        catch {
        }
    }

    return New-Object -ComObject Inventor.Application
}

function Get-VaultPreferencesPath {
    $path = Join-Path $env:APPDATA "Autodesk\Inventor 2026 Vault Addin\ApplicationPreferences.xml"

    if (Test-Path -LiteralPath $path) {
        return $path
    }

    return $null
}

function Set-VaultPromptPreference {
    param(
        [Parameter(Mandatory = $true)]
        [xml]$Xml,

        [Parameter(Mandatory = $true)]
        [string]$CategoryId,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $namespaceUri = $Xml.DocumentElement.NamespaceURI
    $ns = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $ns.AddNamespace("p", $namespaceUri)

    $category = $Xml.SelectSingleNode("//p:Category[@ID='$CategoryId']", $ns)
    if ($null -eq $category) {
        return
    }

    $property = $category.SelectSingleNode("p:Property[@Name='$PropertyName']", $ns)
    if ($null -eq $property) {
        $property = $Xml.CreateElement("Property", $namespaceUri)
        $null = $property.SetAttribute("Name", $PropertyName)
        $null = $property.SetAttribute("Value", $Value)
        $null = $category.AppendChild($property)
    }
    else {
        $null = $property.SetAttribute("Value", $Value)
    }
}

function Set-VaultPromptDefaultsForBatch {
    $preferencesPath = Get-VaultPreferencesPath
    if ([string]::IsNullOrWhiteSpace($preferencesPath)) {
        return
    }

    $xml = New-Object xml
    $xml.Load($preferencesPath)

    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_READONLY_WARN_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_READONLY_WARN_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_CHECKOUT_LOCKED_WARN_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "IDS_CHECKOUT_LOCKED_WARN_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutOnFileEdit_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutOnFileEdit_UserAnswer" -Value "Yes"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutProperties_PromptInstruction" -Value "PromptNever"
    Set-VaultPromptPreference -Xml $xml -CategoryId "VDFPrompts" -PropertyName "CheckOutProperties_UserAnswer" -Value "No"

    $xml.Save($preferencesPath)
}

function Test-InventorRunning {
    try {
        $null = [Runtime.InteropServices.Marshal]::GetActiveObject("Inventor.Application")
        return $true
    }
    catch {
        return $false
    }
}

function Wait-InventorReady {
    param(
        [Parameter(Mandatory = $true)]
        $Inventor,

        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while (-not $Inventor.Ready) {
        if ((Get-Date) -ge $deadline) {
            throw "Inventor did not finish initializing within $TimeoutSeconds seconds."
        }

        Start-Sleep -Milliseconds 500
    }
}

function New-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $sanitized = $Name

    foreach ($char in $invalidChars) {
        $sanitized = $sanitized.Replace($char, "_")
    }

    $sanitized = ($sanitized -replace "\s+", " ").Trim()

    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        return "Unnamed"
    }

    return $sanitized
}

function Get-PartNumber {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $designTracking = $Document.PropertySets.Item("Design Tracking Properties")
        $partNumber = [string]$designTracking.Item("Part Number").Value

        if (-not [string]::IsNullOrWhiteSpace($partNumber)) {
            return $partNumber.Trim()
        }
    }
    catch {
    }

    return [IO.Path]::GetFileNameWithoutExtension([string]$Document.FullFileName)
}

function Hide-DocumentHelpers {
    param(
        [Parameter(Mandatory = $true)]
        $Document
    )

    try {
        $objectVisibility = $Document.ObjectVisibility
    }
    catch {
        return
    }

    try { $objectVisibility.AllWorkFeatures = $false } catch {}
    try { $objectVisibility.UserWorkPlanes = $false } catch {}
    try { $objectVisibility.UserWorkAxes = $false } catch {}
    try { $objectVisibility.UserWorkPoints = $false } catch {}
    try { $objectVisibility.OriginWorkPlanes = $false } catch {}
    try { $objectVisibility.OriginWorkAxes = $false } catch {}
    try { $objectVisibility.OriginWorkPoints = $false } catch {}
    try { $objectVisibility.UCSWorkPlanes = $false } catch {}
    try { $objectVisibility.UCSWorkAxes = $false } catch {}
    try { $objectVisibility.UCSWorkPoints = $false } catch {}
    try { $objectVisibility.Sketches = $false } catch {}
    try { $objectVisibility.Sketches3D = $false } catch {}
    try { $objectVisibility.SketchDimensions = $false } catch {}
}

function Get-ImageFormatInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileType
    )

    switch ($FileType.ToLowerInvariant()) {
        "png" {
            return @{
                Extension = "png"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Png
                SupportsTransparency = $true
            }
        }
        "jpg" {
            return @{
                Extension = "jpg"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Jpeg
                SupportsTransparency = $false
            }
        }
        "bmp" {
            return @{
                Extension = "bmp"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Bmp
                SupportsTransparency = $false
            }
        }
        "gif" {
            return @{
                Extension = "gif"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Gif
                SupportsTransparency = $false
            }
        }
        "tif" {
            return @{
                Extension = "tif"
                ImageFormat = [System.Drawing.Imaging.ImageFormat]::Tiff
                SupportsTransparency = $false
            }
        }
    }
}

function Resolve-OutputBackground {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Background,

        [Parameter(Mandatory = $true)]
        [hashtable]$ImageFormatInfo
    )

    if ($Background.Trim().ToLowerInvariant() -eq "transparent") {
        if (-not $ImageFormatInfo.SupportsTransparency) {
            throw "Transparent background is only supported when -OutputFileType png is used."
        }

        return @{
            Mode = "Transparent"
            Color = [System.Drawing.Color]::Transparent
        }
    }

    try {
        if ($Background.Trim().StartsWith("#")) {
            $color = [System.Drawing.ColorTranslator]::FromHtml($Background)
        }
        else {
            $color = [System.Drawing.Color]::FromName($Background)
        }
    }
    catch {
        throw "Background color '$Background' is invalid. Use a named color like White, a hex value like #F5F5F5, or transparent."
    }

    if ($color.IsEmpty) {
        throw "Background color '$Background' is invalid. Use a named color like White, a hex value like #F5F5F5, or transparent."
    }

    return @{
        Mode = "Solid"
        Color = $color
    }
}

function Save-IsometricSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        $Inventor,

        [Parameter(Mandatory = $true)]
        $Document,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [int]$OutputWidth,

        [Parameter(Mandatory = $true)]
        [int]$OutputHeight,

        [Parameter(Mandatory = $true)]
        [hashtable]$ImageFormatInfo,

        [Parameter(Mandatory = $true)]
        [hashtable]$BackgroundStyle,

        [Parameter(Mandatory = $true)]
        [string]$BackgroundDescription
    )

    $captureStep = "getting active view"

    try {
        $view = $Inventor.ActiveView

        $captureStep = "hiding work features and sketches"
        Hide-DocumentHelpers -Document $Document

        $captureStep = "setting display mode"
        $view.DisplayMode = 8710 # kShadedWithEdgesRendering

        $captureStep = "updating view"
        $view.Update()

        $orientations = @(
            @{ Label = "iso_top_right"; Value = 10759 }  # kIsoTopRightViewOrientation
            @{ Label = "iso_top_left"; Value = 10760 }   # kIsoTopLeftViewOrientation
            @{ Label = "iso_bottom_right"; Value = 10761 } # kIsoBottomRightViewOrientation
            @{ Label = "iso_bottom_left"; Value = 10762 }  # kIsoBottomLeftViewOrientation
        )

        $baseName = New-SafeFileName -Name (Get-PartNumber -Document $Document)
        $bitmapOptions = $Inventor.TransientObjects.CreateNameValueMap()
        $bitmapOptions.Add("TransparentBackground", $true)

        $warmupPath = Join-Path -Path $OutputDirectory -ChildPath "__inventor_snapshot_warmup.tmp.png"
        if (Test-Path -LiteralPath $warmupPath) {
            Remove-Item -LiteralPath $warmupPath -Force
        }

        $captureStep = "warming up first render"
        $warmupCamera = $view.Camera
        $warmupCamera.ViewOrientationType = 10759 # kIsoTopRightViewOrientation
        $warmupCamera.Fit()
        $warmupCamera.Apply()
        Start-Sleep -Milliseconds 300
        $view.Update()
        $view.SaveAsBitmapWithOptions(
            [string]$warmupPath,
            [int]$OutputWidth,
            [int]$OutputHeight,
            $bitmapOptions
        )

        if (Test-Path -LiteralPath $warmupPath) {
            Remove-Item -LiteralPath $warmupPath -Force
        }

        foreach ($orientation in $orientations) {
            $captureStep = "getting camera for $($orientation.Label)"
            $camera = $view.Camera

            $captureStep = "setting orientation to $($orientation.Label)"
            $camera.ViewOrientationType = $orientation.Value

            $captureStep = "fitting camera for $($orientation.Label)"
            $camera.Fit()

            $captureStep = "applying camera for $($orientation.Label)"
            $camera.Apply()

            Start-Sleep -Milliseconds 200

            $captureStep = "updating view for $($orientation.Label)"
            $view.Update()

            $candidateName = "{0}_{1}.{2}" -f $baseName, $orientation.Label, $ImageFormatInfo.Extension
            $targetPath = Join-Path -Path $OutputDirectory -ChildPath $candidateName
            $suffix = 1

            while (Test-Path -LiteralPath $targetPath) {
                $candidateName = "{0}_{1}_{2}.{3}" -f $baseName, $orientation.Label, $suffix, $ImageFormatInfo.Extension
                $targetPath = Join-Path -Path $OutputDirectory -ChildPath $candidateName
                $suffix++
            }

            $tempCapturePath = Join-Path -Path $OutputDirectory -ChildPath ([IO.Path]::GetFileNameWithoutExtension($targetPath) + ".tmp.png")
            if (Test-Path -LiteralPath $tempCapturePath) {
                Remove-Item -LiteralPath $tempCapturePath -Force
            }

            $captureStep = "saving transparent bitmap for $($orientation.Label)"
            $view.SaveAsBitmapWithOptions(
                [string]$tempCapturePath,
                [int]$OutputWidth,
                [int]$OutputHeight,
                $bitmapOptions
            )

            try {
                if ($BackgroundStyle.Mode -eq "Transparent") {
                    $captureStep = "saving transparent output for $($orientation.Label)"
                    Move-Item -LiteralPath $tempCapturePath -Destination $targetPath -Force
                }
                else {
                    $captureStep = "flattening bitmap to $BackgroundDescription background for $($orientation.Label)"
                    $sourceImage = [System.Drawing.Image]::FromFile($tempCapturePath)
                    $compositedBitmap = $null

                    try {
                        $compositedBitmap = New-Object System.Drawing.Bitmap $OutputWidth, $OutputHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

                        $graphics = [System.Drawing.Graphics]::FromImage($compositedBitmap)

                        try {
                            $graphics.Clear($BackgroundStyle.Color)
                            $graphics.DrawImage($sourceImage, 0, 0, $OutputWidth, $OutputHeight)
                        }
                        finally {
                            $graphics.Dispose()
                        }
                    }
                    finally {
                        $sourceImage.Dispose()
                    }

                    $compositedBitmap.Save($targetPath, $ImageFormatInfo.ImageFormat)
                }
            }
            finally {
                if ($null -ne $compositedBitmap) {
                    $compositedBitmap.Dispose()
                }

                if (Test-Path -LiteralPath $tempCapturePath) {
                    Remove-Item -LiteralPath $tempCapturePath -Force
                }
            }
        }
    }
    catch {
        throw "Snapshot step '$captureStep' failed: $($_.Exception.Message)"
    }
}

$resolvedSource = (Resolve-Path -LiteralPath $SourceDirectory).Path
$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$imageFormatInfo = Get-ImageFormatInfo -FileType $OutputFileType
$backgroundStyle = Resolve-OutputBackground -Background $Background -ImageFormatInfo $imageFormatInfo

if (-not (Test-Path -LiteralPath $resolvedOutputDirectory)) {
    New-Item -ItemType Directory -Path $resolvedOutputDirectory | Out-Null
}

$searchOptions = @{
    LiteralPath = $resolvedSource
    File = $true
}

if ($Recurse) {
    $searchOptions.Recurse = $true
}

$files = Get-ChildItem @searchOptions |
    Where-Object { $_.Extension -in ".ipt", ".iam" } |
    Sort-Object FullName

if (-not $files) {
    throw "No .ipt or .iam files were found in '$resolvedSource'."
}

if (-not $UseRunningInventor -and (Test-InventorRunning)) {
    throw "An Inventor session is already running. Close Inventor first, or rerun with -UseRunningInventor if you want to attach to the current session."
}

if (-not $UseRunningInventor) {
    Set-VaultPromptDefaultsForBatch
}

$inventor = Get-InventorApplication -UseRunningInventor:$UseRunningInventor
$inventor.Visible = $true
Wait-InventorReady -Inventor $inventor

$originalScreenUpdating = $inventor.ScreenUpdating
$originalSilentOperation = $inventor.SilentOperation

try {
    $inventor.ScreenUpdating = $false
    $inventor.SilentOperation = $true

    foreach ($file in $files) {
        $document = $null

        try {
            Write-Host ("Processing {0}" -f $file.FullName)

            $currentStep = "opening document"
            $document = $inventor.Documents.Open([string]$file.FullName)

            $currentStep = "activating document"
            $document.Activate()

            $currentStep = "capturing snapshots"
            Save-IsometricSnapshots `
                -Inventor $inventor `
                -Document $document `
                -OutputDirectory $resolvedOutputDirectory `
                -OutputWidth $OutputWidth `
                -OutputHeight $OutputHeight `
                -ImageFormatInfo $imageFormatInfo `
                -BackgroundStyle $backgroundStyle `
                -BackgroundDescription $Background
        }
        catch {
            Write-Warning ("Failed to process '{0}' while {1}: {2}" -f $file.FullName, $currentStep, $_.Exception.Message)
        }
        finally {
            if ($null -ne $document) {
                try {
                    $document.Close($true)
                }
                catch {
                    Write-Warning ("Failed to close '{0}': {1}" -f $file.FullName, $_.Exception.Message)
                }
            }
        }
    }
}
finally {
    $inventor.ScreenUpdating = $originalScreenUpdating
    $inventor.SilentOperation = $originalSilentOperation
}

Write-Host ("Finished. {0} files were saved to: {1}" -f $imageFormatInfo.Extension.ToUpperInvariant(), $resolvedOutputDirectory)
