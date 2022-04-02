#================================================================================
# SCRIPT INPUT PARAMETERS
#================================================================================
param(
    $sampleRate = 15, #Sample increment in minutes
    $logFile = "c:\mrsystems\CoronaEnvironmental-Log.txt"
)

#================================================================================
# SCRIPT GLOBAL VARIABLES
#================================================================================
# Set to true to show debug info in console
$debug = $true

$historianServer = "."
$database = "Runtime"
$username = "aaUser"
$password = 'wwUser'
$uploadUrl = "https://intake.gainesville-dashboard.org"

# Build ArrayList of tagnames and measurement type.
# Be sure to follow the structure below; the Name field is the tagname, and the
# Type field is the measurement type (flow, level, open, closed, etc)
$arTags = @(
    [PSCustomObject]@{
        Name = 'WRFWH_321_GMF_F14_321110_FLOW.ENG_VAI'
        Alias = 'ffi.parshall.q'
        Type = 'flow'
    },
    [PSCustomObject]@{
        Name = 'WRFWH_321_GMF_F58_321109_FLOW.ENG_VAI'
        Alias = 'ffi.scada.discharge.q'
        Type = 'flow'
    }
)


#================================================================================
# DO NOT EDIT BELOW THIS LINE!!
#================================================================================
# Get current date/time for logging
$logDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"


# Build string of tags to lookup in SQL query
$queryTags = ""
for($i = 0; $i -lt $arTags.Count; $i++)
{
    # Add comma separator if there's
    # more than one tag to query
    if($i -gt 0)
    {
        $queryTags += ", "
    }
    
    $queryTags += "'{0}'" -f $arTags[$i].Name
}
if($debug) { write $queryTags`n }


# Build Historian SQL query
$query = "SET NOCOUNT ON`n"
$query += "DECLARE @StartDate DateTime`n"
$query += "DECLARE @EndDate DateTime`n"
$query += "SET @StartDate = DateAdd(hh,-24,GetDate())`n" # Default to lookup the last 24 hours of data
$query += "SET @EndDate = GetDate()`n"
$query += "SET NOCOUNT OFF`n"
$query += "SELECT [what] = 'flow', [when] = DATEDIFF(second, {d '1970-01-01'}, DateTime), temp.TagName as [where], Value as [measurement], [unit] = ISNULL(Cast(EngineeringUnit.Unit as nVarChar(20)),'N/A'), who = 'SCADA', token = 'MySecretTokenWillGoHere' FROM (`n"
$query += "SELECT * FROM History`n"
$query += "WHERE History.TagName IN (" + $queryTags + ")`n"
$query += " AND wwRetrievalMode = 'Cyclic'`n"
$query += " AND wwResolution = " + $sampleRate * 60000 + "`n" # $sampleRate * 60sec/min * 1000ms/sec
$query += " AND wwQualityRule = 'Extended'`n"
$query += " AND wwVersion = 'Latest'`n"
$query += " AND DateTime >= @StartDate AND DateTime <= @EndDate) temp`n"
$query += "LEFT JOIN Tag ON Tag.TagName = temp.TagName`n"
$query += "LEFT JOIN AnalogTag ON AnalogTag.TagName = temp.TagName`n"
$query += "LEFT JOIN EngineeringUnit ON AnalogTag.EUKey = EngineeringUnit.EUKey`n"
$query += "WHERE temp.StartDateTime >= @StartDate"
if($debug) { write $query`n }


# Run SQL Query
$results = Invoke-Sqlcmd -HostName $historianServer -Database $database -Username $username -Password $password -Query $query


# Variable to hold header row and comma-delimited data
$csvData = "what,when,where,measurement,unit,who,token`n"

# Loop through query results, parse & format fields,
# and build comma-delimited records
foreach($result in $results)
{
    # Lookup tag in arTags array above
    $tag = $arTags | Where-Object {$_.Name -eq $result.where}

    # Create csv record with measurement type from arTags lookup
    #$csvData += "{0},{1},{2},{3},{4},{5},{6}`n" -f $tag.Type, $result.when, $tag.Alias, $result.measurement, $result.unit, $result.who, $result.token
    $csvData += "{0},{1},{2},{3},{4},{5},{6}`n" -f $tag.Type, $result.when, $result.where, $result.measurement, $result.unit, $result.who, $result.token
}
if($debug) { write $csvData`n }


# Build POST request
$contentType = "application/json"

# Set security protocol & execute POST request
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$response = Invoke-RestMethod -Uri $uploadUrl -Method Post -ContentType $contentType -Body $csvData

# Log result to log file
"{0} -> {1}`n" -f $logDateTime, $response | Out-File -FilePath $logFile -Append

# Return message
if($response.results.Count > 0)
{
    # Log error messages to log file
    foreach($errResult in $response.results)
    {
        "{0} -> Code:{1}, Row:{2}, Message:{3}, Type:{4}`n" -f $logDateTime, $errResult.code, $errResult.row, $errResult.message, $errResult.type | Out-File -FilePath $logFile -Append
    }

    return "Error occurred. Check log file."
}
elseif($response.message = "All:")
{
    return "Success"
}
