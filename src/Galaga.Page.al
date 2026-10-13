/// <summary>
/// Plays Galaga. The page hosts the "Galaga Screen" control add-in: it receives the input events from the add-in,
/// runs the machine ("Galaga Session" keeps it for the session) for the requested number of frames and sends the
/// frames back.
/// Keys: arrows move, space fires, 5 inserts a coin, 1 / 2 start a 1 / 2 player game, I imports ROMs.
/// The ROM files are managed on the "Galaga ROM Files" page.
/// </summary>
page 66700 Galaga
{
    PageType = UserControlHost;
    Caption = 'Galaga';
    ApplicationArea = All;
    UsageCategory = Tasks;

    layout
    {
        area(Content)
        {
            usercontrol(Screen; "Galaga Screen")
            {
                ApplicationArea = All;

                trigger ControlReady()
                begin
                    StartGalaga();
                end;

                trigger ImportRomsRequested()
                begin
                    if ImportRoms() then begin
                        // a new machine with the new ROMs
                        GalagaSession.Reset();
                        StartGalaga();
                    end;
                end;

                trigger RequestFrames(Input: Text; ElapsedMs: Integer; FrameCount: Integer)
                var
                    T0: DateTime;
                    Frames: Text;
                    Stats: Text;
                begin
                    if not GalagaSession.IsStarted() then
                        exit;
                    T0 := CurrentDateTime();
                    Frames := GalagaSession.RunFrames(Input, FrameCount);
                    Stats := GalagaSession.GetStats();
                    if Stats <> '' then
                        CurrPage.Screen.ShowInfo(Stats);
                    CurrPage.Screen.DrawFrames(Frames, CurrentDateTime() - T0);
                end;
            }
        }
    }

    var
        GalagaSession: Codeunit "Galaga Session";
        MissingRomsTxt: Label 'ROM files are missing: %1.\Import a Galaga romset (galaga.zip or galagao.zip).', Comment = '%1 = list of chips';
        NoColorPromsTxt: Label 'The color PROMs are missing: the colors are made up. Import galaga.zip (the parent romset) for the real colors.';
        ImportedTxt: Label '%1 ROM files imported.', Comment = '%1 = number of files';
        ImportTitleTxt: Label 'Import Galaga ROMs';

    local procedure StartGalaga()
    var
        Missing: Text;
        Palette: Text;
        Waves: Text;
    begin
        if not GalagaSession.Start(Missing) then begin
            CurrPage.Screen.ShowStatus(StrSubstNo(MissingRomsTxt, Missing), true);
            exit;
        end;
        if not GalagaSession.HasColorProms() then
            CurrPage.Screen.ShowMessage(NoColorPromsTxt);
        // the screen may have been (re)loaded: the next frame sends everything
        GalagaSession.GetScreenSetup(Palette, Waves);
        CurrPage.Screen.Init(Palette, Waves);
        CurrPage.Screen.ShowInfo(GalagaSession.GetInitText());
        CurrPage.Screen.Start();
    end;

    local procedure ImportRoms(): Boolean
    var
        Loader: Codeunit "Galaga ROM Loader";
        InS: InStream;
        FileName: Text;
        Imported: Integer;
    begin
        if not UploadIntoStream(ImportTitleTxt, '', 'ROM sets (*.zip)|*.zip|All files (*.*)|*.*', FileName, InS) then
            exit(false);
        Imported := Loader.ImportFile(FileName, InS);
        Message(ImportedTxt, Imported);
        exit(Imported > 0);
    end;
}
