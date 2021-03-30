Get-Volume | Where-Object {$_.DriveLetter -ne $null -and $_.DriveLetter -ne 'A' -and $_.DriveLetter -ne 'D'} | ForEach-Object { 
    $Size = Get-PartitionSupportedSize -DriveLetter $_.DriveLetter
    If ([System.Math]::Round($Size.SizeMax / 1GB,0) -gt [System.Math]::Round($_.Size / 1GB,0)) { 
        Resize-Partition -DriveLetter $_.DriveLetter -Size $Size.SizeMax
    } 
}
