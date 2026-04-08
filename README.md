# InventorAutoGrabber

InventorAutoGrabber is a PowerShell script that works with the native Autodesk Inventor API within windows that automatically creates screenshot image files for a specified folder. This script allows a user to specify a source path (location of your inventor files), and it will generate 4 isometric view pngs of each .ipt and .iam file within the directory. This is intended to help automate the process of generating images for an ERP or CPQ system, or any other customer/employee reference database in which there are a large numbers of unresolved files.

By default, InventorAutoGrabber will export 4 iso pictures (top right, bottom right, top left, bottom left) with the following attributes:

- 2400x2400px
- PNG format
- White background
- View Style: Shaded with Edges
- All work features off

## Contributions

If you'd like to contribute to this script, feel free to submit a pull request. I am not really a programmer, and if you feel it could be enhanced or made better in some way, please reach out.

## Option flags
- *-Recurse*, which scans the directory recursively

- *-OutputWidth*, sets the output image width in pixels (default 2400)
- *-OutputHeight*, sets the output image height in pixels (default 2400)
- *-OutputFileType*, set the default file type (default png)
    - *png*
    - *jpg*
    - *bmp*
    - *gif*
    - *tif*
- *-Background*, sets the output background (default `White`)
    - Named color, such as `White`, `Black`, or `LightGray`
    - Hex color, such as `#F5F5F5`
    - `transparent` when `-OutputFileType png` is used
## Requirements

Currently, this script only support Autodesk Inventor 2026. The year is hardcoded into the script to search for Autodesk Vault Addins so that dialog suppression happens automatically.

## How to Use
1. Download the .ps1 file
2. Open a terminal window in that directory
3. Run the script by specifying: *.\InventorAutoGrabber.ps1 -SourceDirectory "Your Inventor Files Path" -OutputDirectory "Your Output Images Path"*

## Example
>.\InventorAutoGrabber.ps1 -SourceDirectory "C:\Vault Local\Designs\CAD Active\58000\58011" -OutputDirectory "C:\Users\user\Desktop\MyInventorPNGs" -Recurse -OutputFileType jpg -OutputWidth 1920 -OutputHeight 1080

This creates a recursive scan that will output 4 jpgs per file at 1920x1080 resolution.

>.\InventorAutoGrabber.ps1 -SourceDirectory "C:\Vault Local\Designs\CAD Active\58000\58011" -OutputDirectory "C:\Users\user\Desktop\MyInventorPNGs" -Background "#F5F5F5"

This creates PNGs with a light gray background.

>.\InventorAutoGrabber.ps1 -SourceDirectory "C:\Vault Local\Designs\CAD Active\58000\58011" -OutputDirectory "C:\Users\user\Desktop\MyInventorPNGs" -OutputFileType png -Background transparent

This creates PNGs with a transparent background.

## Notes:
When cancelling or finishing a script process, an inventor background process still lingers. It may be necessary to open Task Manager and forcibly close all open inventor processes before opening files from autodesk vault again.
