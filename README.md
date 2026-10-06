# InventorAutoGrabber

InventorAutoGrabber is a PowerShell script that works with the native Autodesk Inventor API within Windows that automatically creates screenshot image files for a specified folder. This script allows a user to specify a source path (location of your inventor files), and it will generate 4 isometric view pngs of each .ipt and .iam file within the directory. This is intended to help automate the process of generating images for an ERP or CPQ system, or any other customer/employee reference database in which there are a large numbers of unresolved files.

## Contributions

If you'd like to contribute to this script, feel free to submit a pull request. I am not really a programmer, and if you feel it could be enhanced or made better in some way, please reach out.

## Flags

By default, InventorAutoGrabber will export 4 iso pictures (top right, bottom right, top left, bottom left) with the following attributes:

- 2400x2400px
- PNG format
- White background
- View Style: Shaded with Edges
- All work features off

### Required Flags

`-src` - Specify the source path of your ipt/iam files

### Optional Flags
`-Recurse` - scans the directory recursively (looks through all sub-folders)
`-out` - sets the output image folder. When this option is not specified, images will be placed in `/output/` in the same path as the script

`-outwidth` - sets the output image width in pixels (default 2400)
`-outheight` - sets the output image height in pixels (default 2400)
`-outext` - set the default file type (default png) Available types:

    `png`
    `jpg`
    `bmp`
    `gif`
    `tif`
`-bg` - sets the output background (default `White`)
    - Named color, such as `White`, `Black`, or `LightGray`
    - Hex color, such as `#F5F5F5`
    - `transparent` when `-outext png` is used

The script displays nested progress bars while processing: the current file's stage and view-capture progress, plus overall job percentage and a job ETA. The ETA is based on the average duration of fully completed files, so it appears after the first file finishes and updates between files.

After each run, a timestamped `iag-run-*.log` report is written to the output folder. It lists files that failed during processing or cleanup and files skipped because they are not `.ipt` or `.iam`. A report is also written when the scan finds no supported files.

## Requirements

Currently, this script only support Autodesk Inventor 2026. The year is hardcoded into the script to search for Autodesk Vault Addins so that dialog suppression happens automatically.

## How to Use
1. Download the iag.ps1 file
2. Open a terminal window in that directory
3. Run the script, specifying your source file directory + any additional options per the examples below

## Example
```powershell
.\iag.ps1 "C:\inventor\files\path"
```
The most basic use of the script. This searches for all .ipt/iam files within the `\path\` top-level directory, and creates a set of 4 isometric PNG output pictures in the folder `/output/`, 2400x2400px square, with a White background in a "Shaded with Edges" style.

```powershell
.\iag.ps1 -src "C:\inventor\files\path" -out "C:\output\images\path" -Recurse -outext jpg -outwidth 1920 -outheight 1080
```
This searches all subfolders within `C:\inventor\files\path` for ipt/iam files, and will output 4 jpgs per file at 1920x1080 resolution to path `C:\output\images\path`.

```powershell
.\iag.ps1 -src "C:\inventor\files\path" -out "C:\output\images\path" -bg "#F5F5F5"
```
This creates PNGs with a light gray background.

```powershell
.\iag.ps1 -src "C:\inventor\files\path" -out "C:\output\images\path" -outext png -bg transparent
```
This creates PNGs with a transparent background.

## Notes:
When the script creates an Inventor session, it closes that session after processing, including when startup or processing fails. If `-UseRunningInventor` attaches to an existing session, that session remains open; only documents opened by the script are closed.
