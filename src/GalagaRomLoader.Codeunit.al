/// <summary>
/// Finds the Galaga ROM files and loads them into the "Galaga Machine".
/// A ROM is recognized by the chip location at the end of its file name (MAME naming, for example gg1-1.3p
/// or gg1_1b.3p), so the sets galaga (Namco rev. B) and galagao (Namco) both work. Imported files
/// ("Galaga ROM File" table) take precedence over the files that ship with the app (the ROMs resource folder).
/// </summary>
codeunit 66701 "Galaga ROM Loader"
{
    var
        RomNotFoundTxt: Label 'No ROM file for %1 (%2) was found.', Comment = '%1 = chip location, e.g. 3p; %2 = what the chip holds';
        NotRomTxt: Label 'The file %1 is not a Galaga ROM file.', Comment = '%1 = file name';

    /// <summary>
    /// Loads all ROMs into the machine. Missing returns the chips that were not found; the color and sound PROMs
    /// are optional (the machine then uses an approximate palette, the add-in its own waveforms).
    /// Returns false when a program or graphics ROM is missing.
    /// </summary>
    procedure LoadRoms(var Machine: Codeunit "Galaga Machine"; var Missing: Text): Boolean
    var
        Resources: List of [Text];
        Slot: Integer;
        Complete: Boolean;
    begin
        Resources := NavApp.ListResources('*');
        Complete := true;
        Missing := '';
        for Slot := 1 to SlotCount() do
            if not LoadSlot(Machine, Slot, Resources) then begin
                if Missing <> '' then
                    Missing += ', ';
                Missing += SlotSuffix(Slot).TrimStart('.') + ' (' + SlotDescription(Slot) + ')';
                if SlotRequired(Slot) then
                    Complete := false;
            end;
        exit(Complete);
    end;

    /// <summary>
    /// Imports a ROM file, or the ROM files in a zip file (a MAME romset), into the "Galaga ROM File" table.
    /// Returns the number of files imported.
    /// </summary>
    procedure ImportFile(FileName: Text; var InS: InStream): Integer
    var
        TempBlob: Codeunit "Temp Blob";
        DataCompression: Codeunit "Data Compression";
        Entries: List of [Text];
        Entry: Text;
        EntryBlob: Codeunit "Temp Blob";
        EntryIn: InStream;
        OutS: OutStream;
        BlobIn: InStream;
        Count: Integer;
    begin
        TempBlob.CreateOutStream(OutS);
        CopyStream(OutS, InS);
        TempBlob.CreateInStream(BlobIn);
        if not DataCompression.IsZip(BlobIn) then begin
            if FindSlot(FileName) = 0 then
                Error(NotRomTxt, FileName);
            TempBlob.CreateInStream(BlobIn);
            StoreFile(FileName, BlobIn);
            exit(1);
        end;
        TempBlob.CreateInStream(BlobIn);
        DataCompression.OpenZipArchive(BlobIn, false);
        DataCompression.GetEntryList(Entries);
        foreach Entry in Entries do
            if FindSlot(Entry) <> 0 then begin
                Clear(EntryBlob);
                DataCompression.ExtractEntry(Entry, EntryBlob);
                EntryBlob.CreateInStream(EntryIn);
                StoreFile(FileNameOf(Entry), EntryIn);
                Count += 1;
            end;
        DataCompression.CloseZipArchive();
        exit(Count);
    end;

    /// <summary>The ROM files found, one per line: chip, file, source.</summary>
    procedure DescribeRoms(): Text
    var
        Resources: List of [Text];
        Result: TextBuilder;
        Slot: Integer;
        FileName: Text;
        Source: Text;
    begin
        Resources := NavApp.ListResources('*');
        for Slot := 1 to SlotCount() do begin
            Source := FindSource(Slot, Resources, FileName);
            if Source = '' then
                Result.AppendLine(StrSubstNo(RomNotFoundTxt, SlotSuffix(Slot).TrimStart('.'), SlotDescription(Slot)))
            else
                Result.AppendLine(SlotSuffix(Slot).TrimStart('.') + ': ' + FileName + ' (' + Source + ')');
        end;
        exit(Result.ToText());
    end;

    local procedure LoadSlot(var Machine: Codeunit "Galaga Machine"; Slot: Integer; Resources: List of [Text]): Boolean
    var
        RomFile: Record "Galaga ROM File";
        InS: InStream;
        FileName: Text;
        Source: Text;
        Offset: Integer;
        Region: Integer;
        Size: Integer;
        b: Byte;
    begin
        Source := FindSource(Slot, Resources, FileName);
        case Source of
            '':
                exit(false);
            'table':
                begin
                    RomFile.SetAutoCalcFields(Data);
                    RomFile.Get(CopyStr(FileName, 1, MaxStrLen(RomFile."File Name")));
                    RomFile.Data.CreateInStream(InS);
                end;
            'app':
                NavApp.GetResource(FileName, InS);
        end;
        Region := SlotRegion(Slot);
        Offset := SlotOffset(Slot);
        Size := SlotSize(Slot);
        while (Size > 0) and (not InS.EOS()) do begin
            InS.Read(b);
            Machine.LoadRom(Region, Offset, b);
            Offset += 1;
            Size -= 1;
        end;
        exit(true);
    end;

    /// <summary>Where the ROM of a slot comes from: 'table', 'app' or '' (not found). FileName returns the file.</summary>
    local procedure FindSource(Slot: Integer; Resources: List of [Text]; var FileName: Text): Text
    var
        RomFile: Record "Galaga ROM File";
        Resource: Text;
    begin
        if RomFile.FindSet() then
            repeat
                if FindSlot(RomFile."File Name") = Slot then begin
                    FileName := RomFile."File Name";
                    exit('table');
                end;
            until RomFile.Next() = 0;
        foreach Resource in Resources do
            if FindSlot(Resource) = Slot then begin
                FileName := Resource;
                exit('app');
            end;
        FileName := '';
        exit('');
    end;

    local procedure StoreFile(FileName: Text; var InS: InStream)
    var
        RomFile: Record "Galaga ROM File";
        OutS: OutStream;
        TempBlob: Codeunit "Temp Blob";
        TempOut: OutStream;
        TempIn: InStream;
    begin
        TempBlob.CreateOutStream(TempOut);
        CopyStream(TempOut, InS);
        // a file for the same chip replaces the one imported before
        if RomFile.FindSet() then
            repeat
                if FindSlot(RomFile."File Name") = FindSlot(FileName) then
                    RomFile.Delete();
            until RomFile.Next() = 0;
        RomFile.Init();
        RomFile."File Name" := CopyStr(FileName, 1, MaxStrLen(RomFile."File Name"));
        RomFile.Size := TempBlob.Length();
        RomFile."Imported At" := CurrentDateTime();
        RomFile.Data.CreateOutStream(OutS);
        TempBlob.CreateInStream(TempIn);
        CopyStream(OutS, TempIn);
        RomFile.Insert();
    end;

    local procedure FileNameOf(Path: Text): Text
    var
        Parts: List of [Text];
    begin
        Parts := Path.Replace('\', '/').Split('/');
        exit(Parts.Get(Parts.Count()));
    end;

    /// <summary>The slot a file name belongs to (by its chip location suffix), 0 if none.</summary>
    procedure FindSlot(FileName: Text): Integer
    var
        Slot: Integer;
    begin
        FileName := FileNameOf(FileName).ToLower();
        for Slot := 1 to SlotCount() do
            if FileName.EndsWith(SlotSuffix(Slot)) then
                exit(Slot);
        exit(0);
    end;

    // ROM slots: chip location suffix, region and offset in the machine (see "Galaga Machine".LoadRom), size

    local procedure SlotCount(): Integer
    begin
        exit(13);
    end;

    local procedure SlotSuffix(Slot: Integer): Text
    begin
        case Slot of
            1:
                exit('.3p');
            2:
                exit('.3m');
            3:
                exit('.2m');
            4:
                exit('.2l');
            5:
                exit('.3f');
            6:
                exit('.2c');
            7:
                exit('.4l');
            8:
                exit('.4d');
            9:
                exit('.4f');
            10:
                exit('.5n');
            11:
                exit('.2n');
            12:
                exit('.1c');
            13:
                exit('.1d');
        end;
    end;

    local procedure SlotDescription(Slot: Integer): Text
    begin
        case Slot of
            1, 2, 3, 4:
                exit('main CPU program');
            5:
                exit('sub CPU program');
            6:
                exit('sound CPU program');
            7:
                exit('characters');
            8, 9:
                exit('sprites');
            10:
                exit('palette PROM');
            11:
                exit('character color PROM');
            12:
                exit('sprite color PROM');
            13:
                exit('sound waveform PROM');
        end;
    end;

    local procedure SlotRequired(Slot: Integer): Boolean
    begin
        exit(Slot <= 9);
    end;

    local procedure SlotRegion(Slot: Integer): Integer
    begin
        case Slot of
            1, 2, 3, 4:
                exit(1);
            5:
                exit(2);
            6:
                exit(3);
            7:
                exit(4);
            8, 9:
                exit(5);
            10:
                exit(6);
            11:
                exit(7);
            12:
                exit(8);
            13:
                exit(9);
        end;
    end;

    local procedure SlotOffset(Slot: Integer): Integer
    begin
        case Slot of
            2:
                exit(4096);
            3:
                exit(8192);
            4:
                exit(12288);
            9:
                exit(4096);
        end;
        exit(0);
    end;

    local procedure SlotSize(Slot: Integer): Integer
    begin
        case Slot of
            10:
                exit(32);
            11, 12, 13:
                exit(256);
        end;
        exit(4096);
    end;
}
