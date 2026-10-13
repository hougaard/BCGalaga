/// <summary>
/// Keeps the Galaga machine for the whole session: closing and opening the Galaga page again resumes the game
/// instead of loading the ROMs and running the power-on test again.
/// </summary>
codeunit 66702 "Galaga Session"
{
    SingleInstance = true;

    var
        Machine: Codeunit "Galaga Machine";
        FrameStat: Integer;
        EmulateMs: Decimal;
        InitText: Text;
        BootTestFrames: Integer;
        BootBatch: Integer;
        MaxBatch: Integer;

    /// <summary>Loads the ROMs and prepares the machine (once per session). Missing returns what was not found.</summary>
    procedure Start(var Missing: Text): Boolean
    var
        Loader: Codeunit "Galaga ROM Loader";
        T0: DateTime;
    begin
        // the power-on self test takes about 740 frames (12 seconds on the real machine): it runs at full speed
        BootTestFrames := 740;
        BootBatch := 30;
        MaxBatch := 10;
        if Machine.IsInitialized() then
            exit(true);
        T0 := CurrentDateTime();
        if not Loader.LoadRoms(Machine, Missing) then begin
            Clear(Machine);
            exit(false);
        end;
        Machine.Initialize();
        InitText := StrSubstNo('init %1', CurrentDateTime() - T0);
        exit(true);
    end;

    /// <summary>Forgets the machine (after new ROMs were imported).</summary>
    procedure Reset()
    begin
        Clear(Machine);
        InitText := '';
    end;

    procedure IsStarted(): Boolean
    begin
        exit(Machine.IsInitialized());
    end;

    procedure HasColorProms(): Boolean
    begin
        exit(Machine.HasColorProms());
    end;

    /// <summary>The colors and waveforms for the add-in, and the next frame sends everything.</summary>
    procedure GetScreenSetup(var Palette: Text; var Waves: Text)
    begin
        Machine.ResetFrameDelta();
        Palette := Machine.GetPaletteText();
        Waves := Machine.GetWaveText();
    end;

    /// <summary>
    /// Applies the input of the add-in and runs FrameCount frames. Returns the frames separated by ';'
    /// (during the power-on test: up to BootBatch frames, of which only the last one is drawn).
    /// </summary>
    procedure RunFrames(Input: Text; FrameCount: Integer): Text
    var
        T0: DateTime;
        Frames: TextBuilder;
        i: Integer;
        BootFrames: Integer;
    begin
        T0 := CurrentDateTime();
        ApplyInput(Input);
        if FrameCount < 1 then
            FrameCount := 1;
        if FrameCount > MaxBatch then
            FrameCount := MaxBatch;
        if Machine.GetFrameNo() < BootTestFrames then begin
            BootFrames := BootTestFrames - Machine.GetFrameNo();
            if BootFrames > BootBatch then
                BootFrames := BootBatch;
            for i := 1 to BootFrames do
                Machine.RunFrame(i = BootFrames);
            Frames.Append(Machine.GetFrameText());
            FrameStat += BootFrames;
        end else
            for i := 1 to FrameCount do begin
                Machine.RunFrame(true);
                if i > 1 then
                    Frames.Append(';');
                Frames.Append(Machine.GetFrameText());
                FrameStat += 1;
            end;
        EmulateMs += CurrentDateTime() - T0;
        exit(Frames.ToText());
    end;

    /// <summary>Timings for the diagnostics line, every 120 frames (empty otherwise).</summary>
    procedure GetStats(): Text
    var
        Stats: Text;
    begin
        if FrameStat < 120 then
            exit('');
        Stats := StrSubstNo('%1 | emulation %2 ms/frame | idle main %3%, sub %4%, sound %5%',
            InitText, Round(EmulateMs / FrameStat, 0.01), Machine.GetIdlePercent(1), Machine.GetIdlePercent(2),
            Machine.GetIdlePercent(3));
        FrameStat := 0;
        EmulateMs := 0;
        exit(Stats);
    end;

    procedure GetInitText(): Text
    begin
        exit(InitText);
    end;

    /// <summary>Input events from the add-in: [0, button] pressed, [1, button] released.</summary>
    local procedure ApplyInput(Input: Text)
    var
        Events: JsonArray;
        EventToken: JsonToken;
        Values: JsonArray;
        Token: JsonToken;
        Button: Integer;
    begin
        if (Input = '') or (Input = '[]') then
            exit;
        if not Events.ReadFrom(Input) then
            exit;
        foreach EventToken in Events do begin
            Values := EventToken.AsArray();
            Values.Get(1, Token);
            Button := Token.AsValue().AsInteger();
            Values.Get(0, Token);
            Machine.SetButton(Button, Token.AsValue().AsInteger() = 0);
        end;
    end;
}
