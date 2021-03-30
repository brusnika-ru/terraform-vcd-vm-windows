$BUS=$args[0]
$UNIT=$args[1]
$LETTER=$args[2]
$LABEL=$args[3]

$DiskDrives = Get-WmiObject Win32_DiskDrive
$DiskInfos = Get-PhysicalDisk | ForEach-Object {
    $PhysicalDisk = $_

    $DiskDrive = $DiskDrives | Where-Object { $_.SerialNumber -eq $PhysicalDisk.SerialNumber }

    New-Object -Type PSCustomObject -Property @{
        "Index" = $DiskDrive.Index
        "Bus"   = $PhysicalDisk.PhysicalLocation
        "Unit"  = $DiskDrive.SCSITargetId
        
        #"Size (GB)" = [System.Math]::Round($PhysicalDisk.Size / 1GB,0);
    }
}

$DiskNum = ( $DiskInfos | Where-Object {$_.Bus -eq "SCSI$BUS" -and $_.Unit -eq "$UNIT"} ).Index

Initialize-Disk $DiskNum -PartitionStyle MBR
New-Partition -DiskNumber $DiskNum -DriveLetter $LETTER -UseMaximumSize
Format-Volume -DriveLetter $LETTER -FileSystem NTFS -NewFileSystemLabel $LABEL -Confirm:$false
