/// <summary>
/// ROM files imported by the user (for example the PROMs from the parent romset galaga.zip).
/// They take precedence over the ROM files that ship with the app as resources.
/// </summary>
table 66700 "Galaga ROM File"
{
    Caption = 'Galaga ROM File';
    DataClassification = SystemMetadata;
    DataPerCompany = false;

    fields
    {
        field(1; "File Name"; Text[100])
        {
            Caption = 'File Name';
        }
        field(2; Data; Blob)
        {
            Caption = 'Data';
        }
        field(3; Size; Integer)
        {
            Caption = 'Size (bytes)';
        }
        field(4; "Imported At"; DateTime)
        {
            Caption = 'Imported At';
        }
    }

    keys
    {
        key(PK; "File Name")
        {
            Clustered = true;
        }
    }
}
