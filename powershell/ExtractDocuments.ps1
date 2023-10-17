
# Connect to a SQL Server (without SQL module installed)
# And extract files stored as IMAGE datatype
# Created with ChatGPT4 

[System.Reflection.Assembly]::LoadWithPartialName("System.Data.SqlClient") | Out-Null

# Set your SQL Server connection parameters
$serverName = "SQLServerInstance"
$databaseName = "YourDatabase"
$connectionString = "Server=$serverName;Database=$databaseName;Integrated Security=True;"

$connection = New-Object System.Data.SqlClient.SqlConnection
$connection.ConnectionString = $connectionString

# Open the connection
$connection.Open()

# Define your SQL query
$query = @"

select --AttachmentID as ID, 
       '_' + convert(varchar(8),CreationDate,112) + '_' + convert(varchar(10),AttachmentID) as ID,
       cast(filecontents as varbinary(max)) as DocumentData,
       FileType as OriginalDocumentType,
       FileName 
  from tt_attachments 
where filecontents is not null
"@


# Specify the folder to save documents
$folderPath = "C:\Extract"



$command = $connection.CreateCommand()
$command.CommandText = $query

# Execute the query
$reader = $command.ExecuteReader()

while ($reader.Read()) {
    $documentID = $reader["ID"]
    $documentData = $reader["DocumentData"]
    $originalDocumentType = $reader["OriginalDocumentType"]
    $originalFileName = $reader["FileName"]


    # Split the original string into parts using "."
    $parts = $originalFileName -split '\.'

    # Check if there are at least two parts (FileName and Ext)
    if ($parts.Length -ge 2) {
        # Insert the number before ".Ext" and rejoin the parts
        $FileName = $parts[0] + "_$documentID" + "." + $parts[1]

        # Output the modified string
        Write-Host $FileName
        } else {
            # Handle the case where the original string doesn't contain both parts
            Write-Host "Invalid input string."
        }


    

    # Check if documentData is not null or empty
    if ($documentData -ne $null -and $documentData.Length -gt 0) {
        # Save the document as its original type (e.g., PDF)
        #$documentPath = "$folderpath\document_$documentID.$originalDocumentType"
        $documentPath = "$folderpath\$FileName"
        [System.IO.File]::WriteAllBytes($documentPath, $documentData)

        Write-Host "$FileName saved to $documentPath"
    } else {
        Write-Host "$documentID $FileName has empty or null data and was not saved."
    }

   
}

# Close the reader, command, and connection
$reader.Close()
$command.Dispose()
$connection.Close()
