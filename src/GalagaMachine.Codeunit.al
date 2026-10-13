/// <summary>
/// The Galaga arcade machine (Namco, 1981) emulated in AL.
/// Three Z80 CPUs (main, sub, sound) share one memory map. The Namco custom chips are emulated at a high
/// level: 06XX (bus interface, NMIs to the main CPU), 51XX (coins, credits, joystick), 54XX (noise sound,
/// reported to the add-in). The video hardware (36x28 tilemap, 64 sprites, 05XX starfield) is rendered into
/// 224x288 layers of palette indexes (the monitor is rotated): the tilemap, the sprites and the stars, which the
/// control add-in stacks. Sound is the state of the Namco WSG registers, which the add-in synthesizes.
/// The procedures between the generated z80 markers come from tools/gen_z80.py.
/// </summary>
codeunit 66700 "Galaga Machine"
{
    var
        // ------------------------------------------------------------ memory
        Mem: array[65536] of Integer;           // 8000-FFFF: video RAM, work RAM, sprite RAM (index = address + 1)
        Rom: array[49160] of Integer;           // 0000-3FFF of each CPU: main 1.., sub 16385.., sound 32769..; scratch 49153..
        RomBase: Integer;                       // 0, 16384 or 32768: the ROM of the running CPU
        RamCode: Boolean;                       // RomBase points to the scratch area (see FetchSlow)
        GfxChars: array[4096] of Integer;       // gg1-9.4l
        GfxSprites: array[8192] of Integer;     // gg1-11.4d, gg1-10.4f
        PromPalette: array[32] of Integer;      // prom-5.5n
        PromCharLut: array[256] of Integer;     // prom-4.2n
        PromSpriteLut: array[256] of Integer;   // prom-3.1c
        PromSound: array[256] of Integer;       // prom-1.1d: 8 waveforms of 32 4-bit samples
        RegionBytes: array[9] of Integer;
        // ------------------------------------------------------------ the running CPU
        rA: Integer;
        rF: Integer;
        rB: Integer;
        rC: Integer;
        rD: Integer;
        rE: Integer;
        rH: Integer;
        rL: Integer;
        AF2: Integer;
        BC2: Integer;
        DE2: Integer;
        HL2: Integer;
        rIX: Integer;
        rIY: Integer;
        rSP: Integer;
        rPC: Integer;
        rI: Integer;
        rR: Integer;                            // R register bits 0-6, as an offset to the cycle counter
        rR7: Integer;                           // R register bit 7 (0 or 128)
        IntMode: Integer;
        IFF1: Boolean;
        IFF2: Boolean;
        Halted: Boolean;
        EiDelay: Boolean;                       // EI was the last instruction: no interrupt yet
        IntPending: Boolean;                    // an interrupt may have to be taken (see CheckInterrupt)
        Cyc: Integer;                           // clock cycles of the running CPU in this frame
        RunTarget: Integer;                     // Execute stops at this cycle
        CpuNo: Integer;                         // 1 main, 2 sub, 3 sound
        CpuState: array[96] of Integer;         // saved registers, 32 per CPU
        IrqLine: array[3] of Boolean;
        NmiPending: array[3] of Boolean;
        // ------------------------------------------------------------ idle loop detection (see IdleCheck)
        WrCnt: Integer;
        IdleT: Integer;
        IdleW: Integer;
        IdleA: Integer;
        IdleF: Integer;
        IdleB: Integer;
        IdleC: Integer;
        IdleD: Integer;
        IdleE: Integer;
        IdleH: Integer;
        IdleL: Integer;
        IdleSP: Integer;
        IdleIX: Integer;
        IdleIY: Integer;
        IdleAF2: Integer;
        IdleBC2: Integer;
        IdleDE2: Integer;
        IdleHL2: Integer;
        SelfIdle: array[3] of Boolean;          // the CPU waits in a loop that only an interrupt can end
        IdleCycles: array[3] of Integer;
        TotalCycles: array[3] of Integer;
        // ------------------------------------------------------------ flag tables
        SZ: array[256] of Integer;
        SZ0: array[256] of Integer;
        SZP: array[256] of Integer;
        SZHVinc: array[256] of Integer;
        SZHVdec: array[256] of Integer;
        XYT: array[256] of Integer;
        AndT: array[65536] of Integer;          // AndT[a * 256 + b + 1] = a and b
        Pow2: array[31] of Integer;
        // ------------------------------------------------------------ board
        MainIrqEnabled: Boolean;
        SubIrqEnabled: Boolean;
        SoundNmiEnabled: Boolean;
        SubHeld: Boolean;                       // sub and sound CPU held in reset
        VideoLatch: array[8] of Integer;        // A000-A007: starfield control, flip screen
        DswGame: Integer;
        DswCoin: Integer;
        Ctrl06: Integer;                        // 06XX control register
        NmiTimerOn: Boolean;
        NmiNext: Integer;
        // ------------------------------------------------------------ 51XX
        Mode51: Integer;                        // 0 switch mode, 1 credit mode, 2 credit mode, game started
        InCount51: Integer;
        CoinCredMode51: Integer;
        Credits51: Integer;
        CoinsPerCred1: Integer;
        CredsPerCoin1: Integer;
        CoinsPerCred2: Integer;
        CredsPerCoin2: Integer;
        Coins1: Integer;
        Coins2: Integer;
        RemapJoy51: Boolean;
        LastCoin1: Boolean;
        LastCoin2: Boolean;
        LastService: Boolean;
        LastStart1: Boolean;
        LastStart2: Boolean;
        LastFire1: Boolean;
        Btn: array[16] of Boolean;
        BtnSeen: array[16] of Boolean;          // the 51XX has read the button since it was pressed
        ReleasePending: array[16] of Boolean;   // released before the 51XX saw it: released when it does
        JoyMap: array[16] of Integer;
        // ------------------------------------------------------------ sound
        SoundReg: array[32] of Integer;
        LastSoundHex: Text;
        SoundTxt: Text;
        // ------------------------------------------------------------ video
        CharPix: array[16384] of Integer;       // 256 chars x 64 pixels, already rotated for the display
        SprPix: array[131072] of Integer;       // 4 flips x 128 sprites x 256 pixels, in display order
        SpanLo: array[8192] of Integer;         // per flip, sprite and display row: first pixel with pen <> 0
        SpanHi: array[8192] of Integer;         // and the last one (SpanLo > SpanHi: none)
        CharLut: array[256] of Integer;         // color * 4 + pen -> palette index (16-31), 96 = transparent
        SprLut: array[256] of Integer;          // color * 4 + pen -> palette index (0-15), -1 = transparent
        TileBase: array[1024] of Integer;       // video RAM offset -> display index of the tile, -1 = not visible
        VramCode: array[1024] of Integer;
        VramColor: array[1024] of Integer;
        TileRowDirty: array[36] of Boolean;     // rows of tiles that changed since the last frame sent
        Layer: array[64513] of Integer;         // the tilemap, 96 where transparent, plus a sentinel
        SprLayer: array[64513] of Integer;      // the sprites, 96 where transparent, plus a sentinel
        Touched: array[65536] of Integer;       // the sprite pixels drawn in the last frame
        TouchedCount: Integer;
        RowMin: array[288] of Integer;          // the columns with sprite pixels per display row (min > max: none)
        RowMax: array[288] of Integer;
        RowHad: array[288] of Boolean;          // the row had sprite pixels in the last frame sent
        StarX: array[256] of Integer;
        StarY: array[256] of Integer;
        StarCol: array[256] of Integer;
        StarSet: array[256] of Integer;
        StarCount: Integer;
        StarScroll: Integer;
        LastStarKey: Integer;
        Tok: array[4096] of Text;
        HexDigit: array[16] of Text;
        FrameTxt: Text;
        StarTxt: Text;
        FrameNo: Integer;
        Initialized: Boolean;

    // ================================================================ public interface

    /// <summary>
    /// Loads one ROM byte. Region: 1 main CPU (0-16383), 2 sub CPU (0-4095), 3 sound CPU (0-4095),
    /// 4 characters (4096), 5 sprites (8192), 6 palette PROM (32), 7 character color PROM (256),
    /// 8 sprite color PROM (256), 9 sound waveform PROM (256).
    /// </summary>
    procedure LoadRom(Region: Integer; Offset: Integer; Value: Integer)
    begin
        case Region of
            1:
                Rom[Offset + 1] := Value;
            2:
                Rom[16384 + Offset + 1] := Value;
            3:
                Rom[32768 + Offset + 1] := Value;
            4:
                GfxChars[Offset + 1] := Value;
            5:
                GfxSprites[Offset + 1] := Value;
            6:
                PromPalette[Offset + 1] := Value;
            7:
                PromCharLut[Offset + 1] := Value;
            8:
                PromSpriteLut[Offset + 1] := Value;
            9:
                PromSound[Offset + 1] := Value;
        end;
        RegionBytes[Region] += 1;
    end;

    /// <summary>Prepares the machine after the ROMs are loaded and resets it.</summary>
    procedure Initialize()
    begin
        DswGame := 247;     // easy, demo sounds on, freeze off, rack test off, upright cabinet
        DswCoin := 151;     // 1 coin 1 credit, bonus 20K 70K every 70K, 3 ships
        InitTables();
        DecodeGraphics();
        BuildColors();
        InitStars();
        InitTiles();
        ResetMachine();
        Initialized := true;
    end;

    procedure IsInitialized(): Boolean
    begin
        exit(Initialized);
    end;

    /// <summary>True when the color PROMs were loaded (otherwise an approximate palette is used).</summary>
    procedure HasColorProms(): Boolean
    begin
        exit((RegionBytes[6] >= 32) and (RegionBytes[7] >= 256) and (RegionBytes[8] >= 256));
    end;

    procedure HasSoundProm(): Boolean
    begin
        exit(RegionBytes[9] >= 256);
    end;

    /// <summary>Bytes loaded into a ROM region (see LoadRom).</summary>
    procedure GetRegionBytes(Region: Integer): Integer
    begin
        exit(RegionBytes[Region]);
    end;

    /// <summary>The dip switches as two bytes (see Initialize for the defaults).</summary>
    procedure SetDipSwitches(NewDswGame: Integer; NewDswCoin: Integer)
    begin
        DswGame := NewDswGame;
        DswCoin := NewDswCoin;
    end;

    /// <summary>
    /// A button changed. 1 left, 2 right, 3 up, 4 down, 5 fire, 6 coin, 7 start 1 player, 8 start 2 players,
    /// 9 coin 2, 10 test switch, 11 service credit.
    /// A press is kept until the 51XX has read it, so a key tapped between two frame requests is not lost.
    /// </summary>
    procedure SetButton(Button: Integer; Pressed: Boolean)
    begin
        if (Button < 1) or (Button > 16) then
            exit;
        if Pressed then begin
            Btn[Button] := true;
            BtnSeen[Button] := false;
            ReleasePending[Button] := false;
        end else
            if BtnSeen[Button] then
                Btn[Button] := false
            else
                ReleasePending[Button] := true;
    end;

    /// <summary>Power on reset.</summary>
    procedure ResetMachine()
    var
        i: Integer;
    begin
        for i := 1 to 65536 do
            Mem[i] := 0;
        for i := 1 to 3 do begin
            ResetCpu(i);
            IrqLine[i] := false;
            NmiPending[i] := false;
            SelfIdle[i] := false;
        end;
        // the LS259 latches start with all outputs low
        MainIrqEnabled := false;
        SubIrqEnabled := false;
        SoundNmiEnabled := true;
        SubHeld := true;
        for i := 1 to 8 do
            VideoLatch[i] := 0;
        Ctrl06 := 0;
        NmiTimerOn := false;
        NmiNext := 0;
        Mode51 := 0;
        InCount51 := 0;
        CoinCredMode51 := 0;
        Credits51 := 0;
        CoinsPerCred1 := 1;
        CredsPerCoin1 := 1;
        CoinsPerCred2 := 1;
        CredsPerCoin2 := 1;
        Coins1 := 0;
        Coins2 := 0;
        RemapJoy51 := false;
        for i := 1 to 32 do
            SoundReg[i] := 0;
        SoundTxt := '';
        StarScroll := 0;
        FrameNo := 0;
        for i := 1 to 1024 do begin
            VramCode[i] := -1;
            VramColor[i] := -1;
        end;
        for i := 1 to 64512 do begin
            Layer[i] := 96;
            SprLayer[i] := 96;
        end;
        // the run length encoding reads one pixel past the last row (AL evaluates both sides of 'and')
        Layer[64513] := -1;
        SprLayer[64513] := -1;
        TouchedCount := 0;
        for i := 1 to 288 do begin
            RowMin[i] := 999;
            RowMax[i] := -1;
        end;
        ResetFrameDelta();
    end;

    /// <summary>
    /// Emulates one video frame (60.6 Hz): 264 scan lines of 192 CPU cycles for each of the three CPUs, run in
    /// slices of four lines. With Render the frame is drawn at the start of vblank; GetFrameText returns it.
    /// </summary>
    procedure RunFrame(Render: Boolean)
    var
        Slice: Integer;
        Line: Integer;
        SliceEnd: Integer;
    begin
        for Slice := 0 to 65 do begin
            Line := Slice * 4;
            // the sound CPU gets an NMI on lines 64 and 192
            if (Line = 64) or (Line = 192) then
                if SoundNmiEnabled and (not SubHeld) then
                    NmiPending[3] := true;
            if Line = 224 then
                VBlank(Render);
            SliceEnd := (Slice + 1) * 768;
            RunMain(SliceEnd);
            if not SubHeld then begin
                // a CPU waiting in a loop that only an interrupt can end does not need to run
                if SelfIdle[2] and (not NmiPending[2]) and (not (IrqLine[2] and (CpuState[53] = 1))) then begin
                    IdleCycles[2] += SliceEnd - CpuState[63];
                    CpuState[63] := SliceEnd;
                end else
                    RunCpu(2, SliceEnd);
                if SelfIdle[3] and (not NmiPending[3]) and (not (IrqLine[3] and (CpuState[85] = 1))) then begin
                    IdleCycles[3] += SliceEnd - CpuState[95];
                    CpuState[95] := SliceEnd;
                end else
                    RunCpu(3, SliceEnd);
            end;
            // the sound registers twice per frame: the add-in applies the second half a frame later
            if Slice = 31 then
                SnapshotSound(0);
            if Slice = 65 then
                SnapshotSound(1);
        end;
        WrCnt := 0;
        TotalCycles[1] += 50688;
        if not SubHeld then begin
            TotalCycles[2] += 50688;
            TotalCycles[3] += 50688;
        end;
        // the next frame starts at cycle 0
        CpuState[31] -= 50688;
        CpuState[63] -= 50688;
        CpuState[95] -= 50688;
        NmiNext -= 50688;
    end;

    /// <summary>
    /// The frame for the add-in: "video!stars!sound".
    /// Video is a list of 2 character tokens (12 bits each, URL safe base64 digits):
    ///   0-3103 a run: color * 32 + length - 1 (color 96 = transparent)
    ///   3200 + row: a row of the tilemap layer follows (224 pixels of runs)
    ///   3500 + row: a row of the sprite layer follows: the row is cleared, runs start at column 0
    ///   3800 + column: the next run starts at this column
    /// Only the rows that changed are sent; empty when no frame was rendered, '-' when nothing changed.
    /// Stars: '=' unchanged, otherwise 2 tokens per star: row * 8 + color div 8, column * 8 + color mod 8
    /// (the star color is 32 + color). Stars show where the tilemap and the sprites are transparent.
    /// Sound is a list of events separated by ',': w(half)(32 hex WSG registers) = the sound registers changed,
    /// n(2 hex) = a byte sent to the 54XX.
    /// </summary>
    procedure GetFrameText(): Text
    var
        Result: Text;
    begin
        if FrameTxt = '' then
            Result := '!=!' + SoundTxt
        else
            Result := FrameTxt + '!' + StarTxt + '!' + SoundTxt;
        FrameTxt := '';
        SoundTxt := '';
        exit(Result);
    end;

    /// <summary>Makes the next frame send everything (e.g. after the add-in was reloaded).</summary>
    procedure ResetFrameDelta()
    var
        i: Integer;
    begin
        for i := 1 to 36 do
            TileRowDirty[i] := true;
        for i := 1 to 288 do
            RowHad[i] := true;
        LastStarKey := -1;
        LastSoundHex := '';
    end;

    /// <summary>The 97 colors (32 from the palette PROM, 64 star colors, black) as RRGGBB hex.</summary>
    procedure GetPaletteText(): Text
    var
        TB: TextBuilder;
        i: Integer;
        v: Integer;
        Lvl: array[4] of Integer;
    begin
        for i := 0 to 31 do begin
            v := PromPalette[i + 1];
            TB.Append(Hex2(33 * (v mod 2) + 71 * ((v div 2) mod 2) + 151 * ((v div 4) mod 2)));
            TB.Append(Hex2(33 * ((v div 8) mod 2) + 71 * ((v div 16) mod 2) + 151 * ((v div 32) mod 2)));
            TB.Append(Hex2(71 * ((v div 64) mod 2) + 151 * (v div 128)));
        end;
        Lvl[1] := 0;
        Lvl[2] := 71;
        Lvl[3] := 151;
        Lvl[4] := 222;
        for i := 0 to 63 do begin
            TB.Append(Hex2(Lvl[i mod 4 + 1]));
            TB.Append(Hex2(Lvl[(i div 4) mod 4 + 1]));
            TB.Append(Hex2(Lvl[(i div 16) mod 4 + 1]));
        end;
        TB.Append('000000');
        exit(TB.ToText());
    end;

    /// <summary>The 8 waveforms of the sound PROM as 256 hex digits, empty when the PROM is missing.</summary>
    procedure GetWaveText(): Text
    var
        TB: TextBuilder;
        i: Integer;
    begin
        if not HasSoundProm() then
            exit('');
        for i := 1 to 256 do
            TB.Append(HexDigit[PromSound[i] mod 16 + 1]);
        exit(TB.ToText());
    end;

    procedure GetFrameNo(): Integer
    begin
        exit(FrameNo);
    end;

    /// <summary>A CPU register (for diagnostics): Cpu 1-3, Reg 0 PC, 1 SP, 2 A, 3 F.</summary>
    procedure GetCpuRegister(Cpu: Integer; Reg: Integer): Integer
    var
        o: Integer;
    begin
        o := (Cpu - 1) * 32;
        case Reg of
            0:
                exit(CpuState[o + 16]);
            1:
                exit(CpuState[o + 15]);
            2:
                exit(CpuState[o + 1]);
            3:
                exit(CpuState[o + 2]);
        end;
        exit(0);
    end;

    /// <summary>
    /// The percentage of a CPU's cycles that were skipped because it waited in an idle loop, since the last call.
    /// </summary>
    procedure GetIdlePercent(Cpu: Integer): Integer
    var
        Result: Integer;
    begin
        Result := 0;
        if TotalCycles[Cpu] >= 100 then
            Result := IdleCycles[Cpu] div (TotalCycles[Cpu] div 100);
        IdleCycles[Cpu] := 0;
        TotalCycles[Cpu] := 0;
        exit(Result);
    end;

    procedure PeekMemory(Address: Integer): Integer
    begin
        if Address < 16384 then
            exit(Rom[Address + 1]);
        if Address >= 32768 then
            exit(Mem[Address + 1]);
        exit(0);
    end;

    // ================================================================ scheduling

    local procedure RunMain(SliceEnd: Integer)
    begin
        LoadCpu(1);
        while Cyc < SliceEnd do begin
            RunTarget := SliceEnd;
            if NmiTimerOn and (NmiNext < RunTarget) then
                RunTarget := NmiNext;
            if Cyc < RunTarget then
                Execute();
            // the 06XX interrupts the main CPU every 200 microseconds while a transfer is going on
            if NmiTimerOn and (Cyc >= NmiNext) then begin
                NmiPending[1] := true;
                IntPending := true;
                NmiNext += 614;
            end;
        end;
        SaveCpu(1);
    end;

    local procedure RunCpu(No: Integer; SliceEnd: Integer)
    begin
        LoadCpu(No);
        RunTarget := SliceEnd;
        if Cyc < RunTarget then
            Execute();
        SaveCpu(No);
    end;

    local procedure VBlank(Render: Boolean)
    begin
        if Render then
            RenderFrame();
        ScrollStars();
        if MainIrqEnabled then
            IrqLine[1] := true;
        if SubIrqEnabled then
            IrqLine[2] := true;
        FrameNo += 1;
    end;

    local procedure ResetCpu(No: Integer)
    var
        o: Integer;
        i: Integer;
    begin
        o := (No - 1) * 32;
        for i := 1 to 32 do
            CpuState[o + i] := 0;
        CpuState[o + 1] := 255;     // A
        CpuState[o + 2] := 255;     // F
        CpuState[o + 13] := 65535;  // IX
        CpuState[o + 14] := 65535;  // IY
        CpuState[o + 15] := 65535;  // SP
    end;

    local procedure SaveCpu(No: Integer)
    var
        o: Integer;
    begin
        o := (No - 1) * 32;
        CpuState[o + 1] := rA;
        CpuState[o + 2] := rF;
        CpuState[o + 3] := rB;
        CpuState[o + 4] := rC;
        CpuState[o + 5] := rD;
        CpuState[o + 6] := rE;
        CpuState[o + 7] := rH;
        CpuState[o + 8] := rL;
        CpuState[o + 9] := AF2;
        CpuState[o + 10] := BC2;
        CpuState[o + 11] := DE2;
        CpuState[o + 12] := HL2;
        CpuState[o + 13] := rIX;
        CpuState[o + 14] := rIY;
        CpuState[o + 15] := rSP;
        CpuState[o + 16] := rPC;
        CpuState[o + 17] := rI;
        CpuState[o + 18] := rR;
        CpuState[o + 19] := rR7;
        CpuState[o + 20] := IntMode;
        if IFF1 then CpuState[o + 21] := 1 else CpuState[o + 21] := 0;
        if IFF2 then CpuState[o + 22] := 1 else CpuState[o + 22] := 0;
        if Halted then CpuState[o + 23] := 1 else CpuState[o + 23] := 0;
        if EiDelay then CpuState[o + 24] := 1 else CpuState[o + 24] := 0;
        CpuState[o + 31] := Cyc;
    end;

    local procedure LoadCpu(No: Integer)
    var
        o: Integer;
    begin
        o := (No - 1) * 32;
        CpuNo := No;
        RomBase := o * 512;
        RamCode := false;
        rA := CpuState[o + 1];
        rF := CpuState[o + 2];
        rB := CpuState[o + 3];
        rC := CpuState[o + 4];
        rD := CpuState[o + 5];
        rE := CpuState[o + 6];
        rH := CpuState[o + 7];
        rL := CpuState[o + 8];
        AF2 := CpuState[o + 9];
        BC2 := CpuState[o + 10];
        DE2 := CpuState[o + 11];
        HL2 := CpuState[o + 12];
        rIX := CpuState[o + 13];
        rIY := CpuState[o + 14];
        rSP := CpuState[o + 15];
        rPC := CpuState[o + 16];
        rI := CpuState[o + 17];
        rR := CpuState[o + 18];
        rR7 := CpuState[o + 19];
        IntMode := CpuState[o + 20];
        IFF1 := CpuState[o + 21] = 1;
        IFF2 := CpuState[o + 22] = 1;
        Halted := CpuState[o + 23] = 1;
        EiDelay := CpuState[o + 24] = 1;
        Cyc := CpuState[o + 31];
        IntPending := NmiPending[No] or EiDelay or (IFF1 and IrqLine[No]);
        SelfIdle[No] := false;
        IdleT := -1;
    end;

    // ================================================================ memory map

    /// <summary>A read outside the inlined fast paths (I/O, or code fetched from outside the ROM).</summary>
    local procedure ReadMem(Addr: Integer): Integer
    var
        o: Integer;
    begin
        if Addr >= 32768 then
            exit(Mem[Addr + 1]);
        if Addr < 16384 then
            exit(Rom[(CpuNo - 1) * 16384 + Addr + 1]);
        // 6800-6807: the dip switches, one bit of each bank per address
        if (Addr >= 26624) and (Addr < 26632) then begin
            o := Addr - 26624 + 1;
            exit(((DswCoin div Pow2[o]) mod 2) + 2 * ((DswGame div Pow2[o]) mod 2));
        end;
        // 7000-70FF: 06XX data, 7100: 06XX control
        if (Addr >= 28672) and (Addr < 28928) then
            exit(Read06xx());
        if Addr = 28928 then
            exit(Ctrl06);
        exit(255);
    end;

    /// <summary>A write outside 8000-9FFF (the RAM writes are inlined).</summary>
    local procedure WriteMem(Addr: Integer; Value: Integer)
    begin
        WrCnt += 1;
        if Addr < 16384 then
            exit;
        if Addr >= 32768 then begin
            if Addr < 40960 then
                Mem[Addr + 1] := Value
            else
                // A000-A007: LS259 latch, starfield control and flip screen
                if Addr < 40968 then
                    VideoLatch[Addr - 40960 + 1] := Value mod 2;
            exit;
        end;
        // 6800-681F: Namco WSG sound registers (4 bits each)
        if (Addr >= 26624) and (Addr < 26656) then begin
            SoundReg[Addr - 26624 + 1] := Value mod 16;
            exit;
        end;
        // 6820-6827: LS259 latch, interrupt enables and the reset line of the other CPUs
        if (Addr >= 26656) and (Addr < 26664) then begin
            MiscLatch(Addr - 26656, Value mod 2);
            exit;
        end;
        if (Addr >= 28672) and (Addr < 28928) then begin
            Write06xx(Value);
            exit;
        end;
        if Addr = 28928 then
            Write06xxCtrl(Value);
        // 6830: watchdog, ignored
    end;

    local procedure MiscLatch(Bit: Integer; State: Integer)
    begin
        case Bit of
            0:
                begin
                    MainIrqEnabled := State = 1;
                    if State = 0 then
                        IrqLine[1] := false;
                end;
            1:
                begin
                    SubIrqEnabled := State = 1;
                    if State = 0 then
                        IrqLine[2] := false;
                end;
            2:
                SoundNmiEnabled := State = 0;
            3:
                if State = 0 then begin
                    if not SubHeld then begin
                        SubHeld := true;
                        ResetCpu(2);
                        ResetCpu(3);
                        IrqLine[2] := false;
                        NmiPending[2] := false;
                        NmiPending[3] := false;
                        SelfIdle[2] := false;
                        SelfIdle[3] := false;
                    end;
                end else
                    if SubHeld then begin
                        // released: the sub and sound CPU start from address 0 now
                        SubHeld := false;
                        CpuState[63] := Cyc;
                        CpuState[95] := Cyc;
                    end;
        end;
    end;

    // ================================================================ Namco 06XX / 51XX / 54XX

    local procedure Write06xxCtrl(Value: Integer)
    begin
        Ctrl06 := Value;
        if Value mod 16 = 0 then begin
            NmiTimerOn := false;
            exit;
        end;
        NmiTimerOn := true;
        NmiNext := Cyc + 614;
        if NmiNext < RunTarget then
            RunTarget := NmiNext;
        // read mode: the 51XX starts its 3 byte answer again
        if (Value div 16) mod 2 = 1 then
            InCount51 := 0;
    end;

    local procedure Read06xx(): Integer
    begin
        if (Ctrl06 div 16) mod 2 = 0 then
            exit(0);
        if Ctrl06 mod 2 = 1 then
            exit(Read51xx());
        exit(255);
    end;

    local procedure Write06xx(Value: Integer)
    begin
        if (Ctrl06 div 16) mod 2 = 1 then
            exit;
        if Ctrl06 mod 2 = 1 then
            Write51xx(Value);
        if (Ctrl06 div 8) mod 2 = 1 then
            // 54XX: the explosion noises. The add-in plays them.
            SoundTxt := SoundTxt + ',n' + Hex2(Value);
    end;

    local procedure Write51xx(Value: Integer)
    begin
        Value := Value mod 8;
        if CoinCredMode51 > 0 then begin
            case CoinCredMode51 of
                4:
                    CoinsPerCred1 := Value;
                3:
                    CredsPerCoin1 := Value;
                2:
                    CoinsPerCred2 := Value;
                1:
                    CredsPerCoin2 := Value;
            end;
            CoinCredMode51 -= 1;
            exit;
        end;
        case Value of
            1:
                begin
                    // set coinage: 4 bytes follow
                    CoinCredMode51 := 4;
                    Credits51 := 0;
                end;
            2:
                begin
                    // credit mode, start buttons enabled
                    Mode51 := 1;
                    InCount51 := 0;
                end;
            3:
                RemapJoy51 := false;
            4:
                RemapJoy51 := true;
            5:
                begin
                    // switch mode
                    Mode51 := 0;
                    InCount51 := 0;
                end;
        end;
    end;

    local procedure Read51xx(): Integer
    var
        Index: Integer;
        Joy: Integer;
        v: Integer;
    begin
        Index := InCount51 mod 3;
        InCount51 += 1;
        if Mode51 = 0 then
            // switch mode: the raw inputs, active low
            case Index of
                0:
                    begin
                        v := 255;
                        if Btn[5] then v -= 1;
                        if Btn[7] then v -= 4;
                        if Btn[8] then v -= 8;
                        if Btn[6] then v -= 16;
                        if Btn[9] then v -= 32;
                        if Btn[11] then v -= 64;
                        if Btn[10] then v -= 128;
                        // coins and start buttons stay pressed until the 51XX counts them (credit mode)
                        MarkSeen(5);
                        MarkSeen(10);
                        exit(v);
                    end;
                1:
                    begin
                        v := 240 + JoyBits();
                        MarkJoySeen();
                        exit(v);
                    end;
                else
                    exit(0);
            end;
        case Index of
            0:
                begin
                    // credit mode: count coins, handle the start buttons, return the credits in BCD
                    if CoinsPerCred1 > 0 then begin
                        if Credits51 < 99 then begin
                            if Btn[6] and (not LastCoin1) then begin
                                Coins1 += 1;
                                if Coins1 >= CoinsPerCred1 then begin
                                    Credits51 += CredsPerCoin1;
                                    Coins1 -= CoinsPerCred1;
                                end;
                            end;
                            if Btn[9] and (not LastCoin2) and (CoinsPerCred2 > 0) then begin
                                Coins2 += 1;
                                if Coins2 >= CoinsPerCred2 then begin
                                    Credits51 += CredsPerCoin2;
                                    Coins2 -= CoinsPerCred2;
                                end;
                            end;
                            if Btn[11] and (not LastService) then
                                Credits51 += 1;
                        end;
                    end else
                        Credits51 := 100;   // free play
                    LastCoin1 := Btn[6];
                    LastCoin2 := Btn[9];
                    LastService := Btn[11];
                    if Mode51 = 1 then begin
                        if Btn[7] and (not LastStart1) then begin
                            if Credits51 >= 1 then begin
                                Credits51 -= 1;
                                Mode51 := 2;
                            end;
                        end else
                            if Btn[8] and (not LastStart2) then
                                if Credits51 >= 2 then begin
                                    Credits51 -= 2;
                                    Mode51 := 2;
                                end;
                    end;
                    LastStart1 := Btn[7];
                    LastStart2 := Btn[8];
                    if Btn[10] then
                        v := 187    // test switch
                    else
                        v := (Credits51 div 10) * 16 + Credits51 mod 10;
                    MarkSeen(6);
                    MarkSeen(7);
                    MarkSeen(8);
                    MarkSeen(9);
                    MarkSeen(10);
                    MarkSeen(11);
                    exit(v);
                end;
            1:
                begin
                    // player 1: direction, bit 4 = fire just pressed (active low), bit 5 = fire held (active low)
                    Joy := JoyBits();
                    if RemapJoy51 then
                        Joy := JoyMap[Joy + 1];
                    if not (Btn[5] and (not LastFire1)) then
                        Joy += 16;
                    if not Btn[5] then
                        Joy += 32;
                    LastFire1 := Btn[5];
                    MarkSeen(5);
                    MarkJoySeen();
                    exit(Joy);
                end;
        end;
        // player 2 (cocktail cabinet only): nothing pressed
        if RemapJoy51 then
            exit(JoyMap[16] + 48);
        exit(15 + 48);
    end;

    local procedure MarkSeen(Button: Integer)
    begin
        BtnSeen[Button] := true;
        if ReleasePending[Button] then begin
            ReleasePending[Button] := false;
            Btn[Button] := false;
        end;
    end;

    local procedure MarkJoySeen()
    begin
        MarkSeen(1);
        MarkSeen(2);
        MarkSeen(3);
        MarkSeen(4);
    end;

    /// <summary>The joystick of player 1 as the hardware sees it: up 1, right 2, down 4, left 8, active low.</summary>
    local procedure JoyBits(): Integer
    var
        v: Integer;
    begin
        v := 15;
        if Btn[3] then v -= 1;
        if Btn[2] then v -= 2;
        if Btn[4] then v -= 4;
        if Btn[1] then v -= 8;
        exit(v);
    end;

    // ================================================================ sound

    local procedure SnapshotSound(Half: Integer)
    var
        TB: TextBuilder;
        Hex: Text;
        i: Integer;
    begin
        for i := 1 to 32 do
            TB.Append(HexDigit[SoundReg[i] + 1]);
        Hex := TB.ToText();
        if Hex = LastSoundHex then
            exit;
        LastSoundHex := Hex;
        SoundTxt := SoundTxt + ',w' + HexDigit[Half + 1] + Hex;
    end;

    // ================================================================ video

    local procedure RenderFrame()
    var
        i: Integer;
    begin
        UpdateTiles();
        // remove the sprites of the previous frame
        for i := 1 to TouchedCount do
            SprLayer[Touched[i]] := 96;
        TouchedCount := 0;
        for i := 1 to 288 do begin
            RowMin[i] := 999;
            RowMax[i] := -1;
        end;
        DrawSprites();
        EncodeFrame();
        EncodeStars();
    end;

    /// <summary>Redraws the tiles whose code or color changed in video RAM.</summary>
    local procedure UpdateTiles()
    var
        Offs: Integer;
        Code: Integer;
        Color: Integer;
        Base: Integer;
        Src: Integer;
        Lut: Integer;
        Dst: Integer;
        y: Integer;
        x: Integer;
    begin
        for Offs := 1 to 1024 do begin
            Code := Mem[32768 + Offs];
            Color := Mem[33792 + Offs];
            if (Code <> VramCode[Offs]) or (Color <> VramColor[Offs]) then begin
                VramCode[Offs] := Code;
                VramColor[Offs] := Color;
                Base := TileBase[Offs];
                if Base >= 0 then begin
                    Src := (Code mod 128) * 64;
                    Lut := (Color mod 64) * 4 + 1;
                    for y := 0 to 7 do begin
                        Dst := Base + y * 224;
                        for x := 1 to 8 do
                            Layer[Dst + x] := CharLut[Lut + CharPix[Src + x]];
                        Src += 8;
                    end;
                    TileRowDirty[Base div 1792 + 1] := true;
                end;
            end;
        end;
    end;

    local procedure DrawSprites()
    var
        Offs: Integer;
        Code: Integer;
        Color: Integer;
        Attr: Integer;
        sx: Integer;
        sy: Integer;
        FlipX: Integer;
        FlipY: Integer;
        SizeX: Integer;
        SizeY: Integer;
        x: Integer;
        y: Integer;
    begin
        // sprite RAM: 8B80 code/color, 9380 position, 9B80 flip/size/position high bits
        Offs := 0;
        while Offs < 128 do begin
            Code := Mem[35713 + Offs] mod 128;
            Color := Mem[35714 + Offs] mod 64;
            Attr := Mem[39809 + Offs];
            sx := Mem[37762 + Offs] - 40 + 256 * (Mem[39810 + Offs] mod 4);
            sy := 256 - Mem[37761 + Offs] + 1;
            FlipX := Attr mod 2;
            FlipY := (Attr div 2) mod 2;
            SizeX := (Attr div 4) mod 2;
            SizeY := (Attr div 8) mod 2;
            sy -= 16 * SizeY;
            sy := ((sy mod 256) + 256) mod 256 - 32;
            if (sx > -32) and (sx < 288) then
                for y := 0 to SizeY do
                    for x := 0 to SizeX do
                        DrawSprite((Code + 2 * ((y + SizeY * FlipY) mod 2) + ((x + SizeX * FlipX) mod 2)) mod 128,
                            Color, FlipX + 2 * FlipY, sx + 16 * x, sy + 16 * y);
            Offs += 2;
        end;
    end;

    /// <summary>
    /// Draws a 16x16 sprite at (Lx, Ly) of the unrotated 288x224 screen into the sprite layer. On the rotated
    /// display, unrotated column Lx + px is display row Lx + px, and unrotated row Ly + py is display column
    /// 223 - Ly - py: SprPix holds the pixels in that order (k = 15 - py).
    /// </summary>
    local procedure DrawSprite(Code: Integer; Color: Integer; Flip: Integer; Lx: Integer; Ly: Integer)
    var
        px: Integer;
        k: Integer;
        k0: Integer;
        k1: Integer;
        Lo: Integer;
        Hi: Integer;
        Row: Integer;
        Col0: Integer;
        Dst: Integer;
        Src: Integer;
        Span: Integer;
        Lut: Integer;
        v: Integer;
        Pen0Opaque: Boolean;
    begin
        if (Lx <= -16) or (Lx >= 288) or (Ly <= -16) or (Ly >= 224) then
            exit;
        Lut := Color * 4 + 1;
        Pen0Opaque := SprLut[Lut] >= 0;
        Col0 := 208 - Ly;
        k0 := 0;
        if Col0 < 0 then
            k0 := -Col0;
        k1 := 15;
        if Col0 + 15 > 223 then
            k1 := 223 - Col0;
        Span := (Flip * 128 + Code) * 16;
        for px := 0 to 15 do begin
            Row := Lx + px;
            if (Row >= 0) and (Row < 288) then begin
                if Pen0Opaque then begin
                    Lo := k0;
                    Hi := k1;
                end else begin
                    Lo := SpanLo[Span + px + 1];
                    Hi := SpanHi[Span + px + 1];
                    if Lo < k0 then
                        Lo := k0;
                    if Hi > k1 then
                        Hi := k1;
                end;
                if Lo <= Hi then begin
                    Dst := Row * 224 + Col0 + 1;
                    Src := (Span + px) * 16 + 1;
                    for k := Lo to Hi do begin
                        v := SprLut[Lut + SprPix[Src + k]];
                        if v >= 0 then begin
                            SprLayer[Dst + k] := v;
                            TouchedCount += 1;
                            Touched[TouchedCount] := Dst + k;
                        end;
                    end;
                    if Col0 + Lo < RowMin[Row + 1] then
                        RowMin[Row + 1] := Col0 + Lo;
                    if Col0 + Hi > RowMax[Row + 1] then
                        RowMax[Row + 1] := Col0 + Hi;
                end;
            end;
        end;
    end;

    /// <summary>
    /// The 05XX starfield: two of the four star sets are shown (they swap to make the stars blink) and the
    /// field scrolls at a speed set by the game. The star positions are an approximation of the real chip.
    /// </summary>
    local procedure EncodeStars()
    var
        TB: TextBuilder;
        i: Integer;
        SetA: Integer;
        SetB: Integer;
        NewKey: Integer;
        x: Integer;
        y: Integer;
    begin
        SetA := VideoLatch[4];
        SetB := VideoLatch[5] + 2;
        NewKey := StarScroll + 256 * (SetA + 4 * SetB + 16 * VideoLatch[6]);
        if NewKey = LastStarKey then begin
            StarTxt := '=';
            exit;
        end;
        LastStarKey := NewKey;
        if VideoLatch[6] = 1 then
            for i := 1 to StarCount do
                if (StarSet[i] = SetA) or (StarSet[i] = SetB) then begin
                    x := (StarX[i] + StarScroll) mod 256 + 16;
                    y := (112 + StarY[i]) mod 256;
                    if y < 224 then begin
                        TB.Append(Tok[x * 8 + StarCol[i] div 8 + 1]);
                        TB.Append(Tok[(223 - y) * 8 + StarCol[i] mod 8 + 1]);
                    end;
                end;
        StarTxt := TB.ToText();
    end;

    local procedure ScrollStars()
    var
        Speed: Integer;
    begin
        case VideoLatch[1] + 2 * VideoLatch[2] + 4 * VideoLatch[3] of
            0:
                Speed := -1;
            1:
                Speed := -2;
            2:
                Speed := -3;
            3:
                Speed := 0;
            4:
                Speed := 3;
            5:
                Speed := 2;
            6:
                Speed := 1;
            7:
                Speed := 0;
        end;
        StarScroll := (StarScroll + Speed + 256) mod 256;
    end;

    /// <summary>Encodes the tilemap rows that changed and the sprite rows (see GetFrameText).</summary>
    local procedure EncodeFrame()
    var
        TB: TextBuilder;
        y: Integer;
        x: Integer;
        n: Integer;
        v: Integer;
        Base: Integer;
        Last: Integer;
        TileRow: Integer;
    begin
        for TileRow := 1 to 36 do
            if TileRowDirty[TileRow] then begin
                TileRowDirty[TileRow] := false;
                for y := (TileRow - 1) * 8 to (TileRow - 1) * 8 + 7 do begin
                    TB.Append(Tok[3201 + y]);
                    Base := y * 224;
                    x := 1;
                    while x <= 224 do begin
                        v := Layer[Base + x];
                        n := 1;
                        while (n < 32) and (x + n <= 224) and (Layer[Base + x + n] = v) do
                            n += 1;
                        TB.Append(Tok[v * 32 + n]);
                        x += n;
                    end;
                end;
            end;
        for y := 0 to 287 do
            if RowMin[y + 1] <= RowMax[y + 1] then begin
                // the row has sprite pixels: send the columns between the first and the last one
                TB.Append(Tok[3501 + y]);
                TB.Append(Tok[3801 + RowMin[y + 1]]);
                Base := y * 224 + 1;
                x := RowMin[y + 1];
                Last := RowMax[y + 1];
                while x <= Last do begin
                    v := SprLayer[Base + x];
                    n := 1;
                    while (n < 32) and (x + n <= Last) and (SprLayer[Base + x + n] = v) do
                        n += 1;
                    TB.Append(Tok[v * 32 + n]);
                    x += n;
                end;
                RowHad[y + 1] := true;
            end else
                if RowHad[y + 1] then begin
                    // the sprites left the row: clear it
                    TB.Append(Tok[3501 + y]);
                    RowHad[y + 1] := false;
                end;
        FrameTxt := TB.ToText();
        if FrameTxt = '' then
            FrameTxt := '-';
    end;

    // ================================================================ initialization

    local procedure InitTables()
    var
        i: Integer;
        a: Integer;
        b: Integer;
        p: Integer;
        v: Integer;
        k: Integer;
        Alphabet: Text;
    begin
        Pow2[1] := 1;
        for i := 2 to 31 do
            Pow2[i] := Pow2[i - 1] * 2;
        for a := 0 to 255 do
            for b := 0 to 255 do
                if (a = 0) or (b = 0) then
                    AndT[a * 256 + b + 1] := 0
                else
                    AndT[a * 256 + b + 1] := 2 * AndT[(a div 2) * 256 + (b div 2) + 1] + (a mod 2) * (b mod 2);
        for i := 0 to 255 do begin
            XYT[i + 1] := AndT[i * 256 + 41];   // undocumented flags: bits 5 and 3 (40)
            if i = 0 then
                SZ0[i + 1] := 64
            else
                if i >= 128 then
                    SZ0[i + 1] := 128
                else
                    SZ0[i + 1] := 0;
            SZ[i + 1] := SZ0[i + 1] + XYT[i + 1];
            p := 0;
            v := i;
            for k := 1 to 8 do begin
                p += v mod 2;
                v := v div 2;
            end;
            if p mod 2 = 0 then
                SZP[i + 1] := SZ[i + 1] + 4
            else
                SZP[i + 1] := SZ[i + 1];
            SZHVinc[i + 1] := SZ[i + 1];
            if i = 128 then
                SZHVinc[i + 1] += 4;
            if i mod 16 = 0 then
                SZHVinc[i + 1] += 16;
            SZHVdec[i + 1] := SZ[i + 1] + 2;
            if i = 127 then
                SZHVdec[i + 1] += 4;
            if i mod 16 = 15 then
                SZHVdec[i + 1] += 16;
        end;
        // 51XX joystick remapping: direction 0 = up, clockwise, 8 = center
        JoyMap[1] := 15;
        JoyMap[2] := 14;
        JoyMap[3] := 13;
        JoyMap[4] := 5;
        JoyMap[5] := 12;
        JoyMap[6] := 9;
        JoyMap[7] := 7;
        JoyMap[8] := 6;
        JoyMap[9] := 11;
        JoyMap[10] := 3;
        JoyMap[11] := 10;
        JoyMap[12] := 4;
        JoyMap[13] := 1;
        JoyMap[14] := 2;
        JoyMap[15] := 0;
        JoyMap[16] := 8;
        // frame tokens: 12 bits as 2 characters of the URL safe base64 alphabet
        Alphabet := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
        for i := 0 to 4095 do
            Tok[i + 1] := CopyStr(Alphabet, i div 64 + 1, 1) + CopyStr(Alphabet, i mod 64 + 1, 1);
        for i := 0 to 15 do
            HexDigit[i + 1] := CopyStr('0123456789ABCDEF', i + 1, 1);
    end;

    local procedure Hex2(Value: Integer): Text
    begin
        exit(HexDigit[Value div 16 + 1] + HexDigit[Value mod 16 + 1]);
    end;

    /// <summary>
    /// Decodes the 2 bits per pixel character and sprite ROMs (MAME's charlayout and spritelayout): both bit planes
    /// of a pixel are in the same byte (bits 7-b and 3-b), PenT has the pen for each byte value and b.
    /// </summary>
    local procedure DecodeGraphics()
    var
        PenT: array[1024] of Integer;
        Code: Integer;
        Flip: Integer;
        px: Integer;
        py: Integer;
        sx: Integer;
        sy: Integer;
        k: Integer;
        b: Integer;
        v: Integer;
        Pen: Integer;
        Span: Integer;
    begin
        for v := 0 to 255 do
            for b := 0 to 3 do
                PenT[v * 4 + b + 1] := 2 * ((v div Pow2[8 - b]) mod 2) + (v div Pow2[4 - b]) mod 2;
        for Code := 0 to 255 do
            for py := 0 to 7 do
                for px := 0 to 7 do
                    // x offsets 64 65 66 67 0 1 2 3, y offsets 0 8 .. 56; stored rotated: display row px, column 7 - py
                    if px < 4 then
                        CharPix[Code * 64 + px * 8 + (7 - py) + 1] := PenT[GfxChars[Code * 16 + 8 + py + 1] * 4 + px + 1]
                    else
                        CharPix[Code * 64 + px * 8 + (7 - py) + 1] := PenT[GfxChars[Code * 16 + py + 1] * 4 + px - 3];
        for Flip := 0 to 3 do
            for Code := 0 to 127 do
                for px := 0 to 15 do begin
                    Span := (Flip * 128 + Code) * 16 + px + 1;
                    SpanLo[Span] := 16;
                    SpanHi[Span] := -1;
                    sx := px;
                    if Flip mod 2 = 1 then
                        sx := 15 - px;
                    for k := 0 to 15 do begin
                        py := 15 - k;
                        sy := py;
                        if Flip >= 2 then
                            sy := 15 - py;
                        // x offsets 0-3 64-67 128-131 192-195, y offsets 0 8 .. 56 256 264 .. 312
                        Pen := PenT[GfxSprites[Code * 64 + (sy div 8) * 32 + sy mod 8 + (sx div 4) * 8 + 1] * 4 + sx mod 4 + 1];
                        SprPix[(Span - 1) * 16 + k + 1] := Pen;
                        if Pen <> 0 then begin
                            if k < SpanLo[Span] then
                                SpanLo[Span] := k;
                            SpanHi[Span] := k;
                        end;
                    end;
                end;
    end;

    /// <summary>
    /// The color lookup tables from the PROMs. Without the PROMs (they are in the parent romset galaga.zip,
    /// not in the clone sets) an approximate palette is made up so the game is playable.
    /// </summary>
    local procedure BuildColors()
    var
        i: Integer;
        v: Integer;
        Colors: Text;
    begin
        if not HasColorProms() then begin
            // black red yellow blue white green cyan magenta orange lightblue darkred purple gray lightgreen pink black
            Colors := '000006054192246048240198038226004212164116166000';
            for i := 0 to 15 do begin
                Evaluate(v, CopyStr(Colors, i * 3 + 1, 3));
                PromPalette[i + 1] := v;
                PromPalette[i + 17] := v;
            end;
            for i := 0 to 255 do
                if i mod 4 = 0 then begin
                    PromCharLut[i + 1] := 15;
                    PromSpriteLut[i + 1] := 15;
                end else begin
                    PromCharLut[i + 1] := 1 + ((i div 4) * 7 + (i mod 4) * 5) mod 14;
                    PromSpriteLut[i + 1] := 1 + ((i div 4) * 3 + (i mod 4) * 4) mod 14;
                end;
        end;
        for i := 1 to 256 do begin
            v := PromCharLut[i] mod 16;
            if v = 15 then
                CharLut[i] := 96
            else
                CharLut[i] := v + 16;
            v := PromSpriteLut[i] mod 16;
            if v = 15 then
                SprLut[i] := -1
            else
                SprLut[i] := v;
        end;
    end;

    /// <summary>Where each video RAM offset is shown (MAME's tilemap_scan for the 36 x 28 tilemap).</summary>
    local procedure InitTiles()
    var
        Col: Integer;
        Row: Integer;
        c: Integer;
        r: Integer;
        Offs: Integer;
    begin
        for Offs := 1 to 1024 do
            TileBase[Offs] := -1;
        for Col := 0 to 35 do
            for Row := 0 to 27 do begin
                r := Row + 2;
                c := Col - 2;
                if c < 0 then
                    c += 64;
                if c >= 32 then
                    Offs := r + (c mod 32) * 32
                else
                    Offs := c + r * 32;
                // unrotated tile (Col, Row) is shown at display row Col * 8, column 216 - Row * 8
                TileBase[Offs + 1] := Col * 8 * 224 + 216 - Row * 8;
            end;
    end;

    local procedure InitStars()
    var
        i: Integer;
        Seed: Integer;
    begin
        Seed := 12345;
        StarCount := 252;
        for i := 1 to StarCount do begin
            Seed := (Seed * 75 + 74) mod 65537;
            StarX[i] := Seed mod 256;
            Seed := (Seed * 75 + 74) mod 65537;
            StarY[i] := Seed mod 256;
            Seed := (Seed * 75 + 74) mod 65537;
            StarCol[i] := 1 + Seed mod 63;
            StarSet[i] := (i - 1) mod 4;
        end;
    end;

    // ================================================================ Z80

    // <generated z80>
    // Generated by tools/gen_z80.py - do not edit by hand.

    /// <summary>Executes the current CPU until Cyc reaches RunTarget.</summary>
    local procedure Execute()
    var
        op: Integer;
        n: Integer;
        t: Integer;
        v: Integer;
        c: Integer;
        d: Integer;
        w: Integer;
        ea: Integer;
        hl: Integer;
    begin
        while Cyc < RunTarget do begin
            if IntPending then
                CheckInterrupt();
            if (rPC < 16384) and (not RamCode) then
                op := Rom[RomBase + rPC + 1]
            else
                op := FetchSlow();
            rPC += 1;
            case op of
                0:
                    Cyc += 4;
                1:
                    begin
                        Cyc += 10;
                        rC := Rom[RomBase + rPC + 1];
                        rB := Rom[RomBase + rPC + 2];
                        rPC += 2;
                    end;
                2:
                    begin
                        Cyc += 7;
                        ea := rB * 256 + rC;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rA then begin Mem[ea + 1] := rA; WrCnt += 1; end; end else WriteMem(ea, rA);
                    end;
                3:
                    begin
                        Cyc += 6;
                        if rC < 255 then rC += 1 else begin rC := 0; if rB = 255 then rB := 0 else rB += 1; end;
                    end;
                4:
                    begin
                        Cyc += 4;
                        if rB = 255 then rB := 0 else rB += 1;
                        rF := (rF mod 2) + SZHVinc[rB + 1];
                    end;
                5:
                    begin
                        Cyc += 4;
                        if rB = 0 then rB := 255 else rB -= 1;
                        rF := (rF mod 2) + SZHVdec[rB + 1];
                    end;
                6:
                    begin
                        Cyc += 7;
                        rB := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                7:
                    begin
                        Cyc += 4;
                        c := rA div 128;
                        rA := (rA * 2) mod 256 + c;
                        rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];
                    end;
                8:
                    begin
                        Cyc += 4;
                        t := rA * 256 + rF;
                        rA := AF2 div 256;
                        rF := AF2 mod 256;
                        AF2 := t;
                    end;
                9:
                    begin
                        Cyc += 11;
                        w := rB * 256 + rC;
                        hl := rH * 256 + rL;
                        t := hl + w;
                        rF := AndT[rF * 256 + 197];
                        if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                        if t > 65535 then begin t -= 65536; rF += 1; end;
                        rH := t div 256;
                        rL := t mod 256;
                        rF += XYT[t div 256 + 1];
                    end;
                10:
                    begin
                        Cyc += 7;
                        ea := rB * 256 + rC;
                        if ea >= 32768 then rA := Mem[ea + 1] else if ea < 16384 then rA := Rom[RomBase + ea + 1] else rA := ReadMem(ea);
                    end;
                11:
                    begin
                        Cyc += 6;
                        if rC > 0 then rC -= 1 else begin rC := 255; if rB = 0 then rB := 255 else rB -= 1; end;
                    end;
                12:
                    begin
                        Cyc += 4;
                        if rC = 255 then rC := 0 else rC += 1;
                        rF := (rF mod 2) + SZHVinc[rC + 1];
                    end;
                13:
                    begin
                        Cyc += 4;
                        if rC = 0 then rC := 255 else rC -= 1;
                        rF := (rF mod 2) + SZHVdec[rC + 1];
                    end;
                14:
                    begin
                        Cyc += 7;
                        rC := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                15:
                    begin
                        Cyc += 4;
                        c := rA mod 2;
                        rA := rA div 2 + c * 128;
                        rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];
                    end;
                16:
                    begin
                        Cyc += 8;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        if rB = 0 then rB := 255 else rB -= 1;
                        if rB <> 0 then begin rPC := (rPC + d + 65536) mod 65536; Cyc += 5; end;
                    end;
                17:
                    begin
                        Cyc += 10;
                        rE := Rom[RomBase + rPC + 1];
                        rD := Rom[RomBase + rPC + 2];
                        rPC += 2;
                    end;
                18:
                    begin
                        Cyc += 7;
                        ea := rD * 256 + rE;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rA then begin Mem[ea + 1] := rA; WrCnt += 1; end; end else WriteMem(ea, rA);
                    end;
                19:
                    begin
                        Cyc += 6;
                        if rE < 255 then rE += 1 else begin rE := 0; if rD = 255 then rD := 0 else rD += 1; end;
                    end;
                20:
                    begin
                        Cyc += 4;
                        if rD = 255 then rD := 0 else rD += 1;
                        rF := (rF mod 2) + SZHVinc[rD + 1];
                    end;
                21:
                    begin
                        Cyc += 4;
                        if rD = 0 then rD := 255 else rD -= 1;
                        rF := (rF mod 2) + SZHVdec[rD + 1];
                    end;
                22:
                    begin
                        Cyc += 7;
                        rD := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                23:
                    begin
                        Cyc += 4;
                        c := rA div 128;
                        rA := (rA * 2) mod 256 + rF mod 2;
                        rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];
                    end;
                24:
                    begin
                        Cyc += 12;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        rPC := (rPC + d + 65536) mod 65536;
                        if (d < 0) and (d >= -20) then begin
                            if d = -2 then begin
                                SelfIdle[CpuNo] := true;
                                IdleCycles[CpuNo] += RunTarget - Cyc;
                                Cyc := RunTarget;
                            end else
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                        end;
                    end;
                25:
                    begin
                        Cyc += 11;
                        w := rD * 256 + rE;
                        hl := rH * 256 + rL;
                        t := hl + w;
                        rF := AndT[rF * 256 + 197];
                        if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                        if t > 65535 then begin t -= 65536; rF += 1; end;
                        rH := t div 256;
                        rL := t mod 256;
                        rF += XYT[t div 256 + 1];
                    end;
                26:
                    begin
                        Cyc += 7;
                        ea := rD * 256 + rE;
                        if ea >= 32768 then rA := Mem[ea + 1] else if ea < 16384 then rA := Rom[RomBase + ea + 1] else rA := ReadMem(ea);
                    end;
                27:
                    begin
                        Cyc += 6;
                        if rE > 0 then rE -= 1 else begin rE := 255; if rD = 0 then rD := 255 else rD -= 1; end;
                    end;
                28:
                    begin
                        Cyc += 4;
                        if rE = 255 then rE := 0 else rE += 1;
                        rF := (rF mod 2) + SZHVinc[rE + 1];
                    end;
                29:
                    begin
                        Cyc += 4;
                        if rE = 0 then rE := 255 else rE -= 1;
                        rF := (rF mod 2) + SZHVdec[rE + 1];
                    end;
                30:
                    begin
                        Cyc += 7;
                        rE := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                31:
                    begin
                        Cyc += 4;
                        c := rA mod 2;
                        rA := rA div 2 + (rF mod 2) * 128;
                        rF := AndT[rF * 256 + 197] + c + XYT[rA + 1];
                    end;
                32:
                    begin
                        Cyc += 7;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        if (rF mod 128) < 64 then begin
                            rPC := (rPC + d + 65536) mod 65536;
                            Cyc += 5;
                            if (d < 0) and (d >= -20) then begin
                                if d = -2 then begin
                                    SelfIdle[CpuNo] := true;
                                    IdleCycles[CpuNo] += RunTarget - Cyc;
                                    Cyc := RunTarget;
                                end else
                                    if rPC <> IdleT then begin
                                        IdleT := rPC;
                                        IdleW := -1;
                                    end else
                                        IdleCheck();
                            end;
                        end;
                    end;
                33:
                    begin
                        Cyc += 10;
                        rL := Rom[RomBase + rPC + 1];
                        rH := Rom[RomBase + rPC + 2];
                        rPC += 2;
                    end;
                34:
                    begin
                        Cyc += 16;
                        ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rL then begin Mem[ea + 1] := rL; WrCnt += 1; end; end else WriteMem(ea, rL);
                        ea := (ea + 1) mod 65536;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rH then begin Mem[ea + 1] := rH; WrCnt += 1; end; end else WriteMem(ea, rH);
                    end;
                35:
                    begin
                        Cyc += 6;
                        if rL < 255 then rL += 1 else begin rL := 0; if rH = 255 then rH := 0 else rH += 1; end;
                    end;
                36:
                    begin
                        Cyc += 4;
                        if rH = 255 then rH := 0 else rH += 1;
                        rF := (rF mod 2) + SZHVinc[rH + 1];
                    end;
                37:
                    begin
                        Cyc += 4;
                        if rH = 0 then rH := 255 else rH -= 1;
                        rF := (rF mod 2) + SZHVdec[rH + 1];
                    end;
                38:
                    begin
                        Cyc += 7;
                        rH := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                39:
                    begin
                        Cyc += 4;
                        t := rA;
                        if (rF mod 4) >= 2 then begin
                            if ((rF mod 32) >= 16) or ((rA mod 16) > 9) then t -= 6;
                            if ((rF mod 2) = 1) or (rA > 153) then t -= 96;
                        end else begin
                            if ((rF mod 32) >= 16) or ((rA mod 16) > 9) then t += 6;
                            if ((rF mod 2) = 1) or (rA > 153) then t += 96;
                        end;
                        t := (t + 512) mod 256;
                        c := AndT[rF * 256 + 4];
                        if rA > 153 then c := c - (c mod 2) + 1;
                        if ((rA div 16) mod 2) <> ((t div 16) mod 2) then c += 16;
                        rA := t;
                        rF := c + SZP[rA + 1];
                    end;
                40:
                    begin
                        Cyc += 7;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        if (rF mod 128) >= 64 then begin
                            rPC := (rPC + d + 65536) mod 65536;
                            Cyc += 5;
                            if (d < 0) and (d >= -20) then begin
                                if d = -2 then begin
                                    SelfIdle[CpuNo] := true;
                                    IdleCycles[CpuNo] += RunTarget - Cyc;
                                    Cyc := RunTarget;
                                end else
                                    if rPC <> IdleT then begin
                                        IdleT := rPC;
                                        IdleW := -1;
                                    end else
                                        IdleCheck();
                            end;
                        end;
                    end;
                41:
                    begin
                        Cyc += 11;
                        w := rH * 256 + rL;
                        hl := rH * 256 + rL;
                        t := hl + w;
                        rF := AndT[rF * 256 + 197];
                        if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                        if t > 65535 then begin t -= 65536; rF += 1; end;
                        rH := t div 256;
                        rL := t mod 256;
                        rF += XYT[t div 256 + 1];
                    end;
                42:
                    begin
                        Cyc += 16;
                        ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if ea >= 32768 then rL := Mem[ea + 1] else if ea < 16384 then rL := Rom[RomBase + ea + 1] else rL := ReadMem(ea);
                        ea := (ea + 1) mod 65536;
                        if ea >= 32768 then rH := Mem[ea + 1] else if ea < 16384 then rH := Rom[RomBase + ea + 1] else rH := ReadMem(ea);
                    end;
                43:
                    begin
                        Cyc += 6;
                        if rL > 0 then rL -= 1 else begin rL := 255; if rH = 0 then rH := 255 else rH -= 1; end;
                    end;
                44:
                    begin
                        Cyc += 4;
                        if rL = 255 then rL := 0 else rL += 1;
                        rF := (rF mod 2) + SZHVinc[rL + 1];
                    end;
                45:
                    begin
                        Cyc += 4;
                        if rL = 0 then rL := 255 else rL -= 1;
                        rF := (rF mod 2) + SZHVdec[rL + 1];
                    end;
                46:
                    begin
                        Cyc += 7;
                        rL := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                47:
                    begin
                        Cyc += 4;
                        rA := 255 - rA;
                        rF := AndT[rF * 256 + 198] + 18 + XYT[rA + 1];
                    end;
                48:
                    begin
                        Cyc += 7;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        if (rF mod 2) = 0 then begin
                            rPC := (rPC + d + 65536) mod 65536;
                            Cyc += 5;
                            if (d < 0) and (d >= -20) then begin
                                if d = -2 then begin
                                    SelfIdle[CpuNo] := true;
                                    IdleCycles[CpuNo] += RunTarget - Cyc;
                                    Cyc := RunTarget;
                                end else
                                    if rPC <> IdleT then begin
                                        IdleT := rPC;
                                        IdleW := -1;
                                    end else
                                        IdleCheck();
                            end;
                        end;
                    end;
                49:
                    begin
                        Cyc += 10;
                        rSP := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                    end;
                50:
                    begin
                        Cyc += 13;
                        ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rA then begin Mem[ea + 1] := rA; WrCnt += 1; end; end else WriteMem(ea, rA);
                    end;
                51:
                    begin
                        Cyc += 6;
                        rSP := (rSP + 1) mod 65536;
                    end;
                52:
                    begin
                        Cyc += 11;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        if v = 255 then v := 0 else v += 1;
                        rF := (rF mod 2) + SZHVinc[v + 1];
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    end;
                53:
                    begin
                        Cyc += 11;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        if v = 0 then v := 255 else v -= 1;
                        rF := (rF mod 2) + SZHVdec[v + 1];
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    end;
                54:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> n then begin Mem[ea + 1] := n; WrCnt += 1; end; end else WriteMem(ea, n);
                    end;
                55:
                    begin
                        Cyc += 4;
                        rF := AndT[rF * 256 + 197] + 1 + XYT[rA + 1];
                    end;
                56:
                    begin
                        Cyc += 7;
                        d := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        if d >= 128 then d -= 256;
                        if (rF mod 2) = 1 then begin
                            rPC := (rPC + d + 65536) mod 65536;
                            Cyc += 5;
                            if (d < 0) and (d >= -20) then begin
                                if d = -2 then begin
                                    SelfIdle[CpuNo] := true;
                                    IdleCycles[CpuNo] += RunTarget - Cyc;
                                    Cyc := RunTarget;
                                end else
                                    if rPC <> IdleT then begin
                                        IdleT := rPC;
                                        IdleW := -1;
                                    end else
                                        IdleCheck();
                            end;
                        end;
                    end;
                57:
                    begin
                        Cyc += 11;
                        w := rSP;
                        hl := rH * 256 + rL;
                        t := hl + w;
                        rF := AndT[rF * 256 + 197];
                        if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                        if t > 65535 then begin t -= 65536; rF += 1; end;
                        rH := t div 256;
                        rL := t mod 256;
                        rF += XYT[t div 256 + 1];
                    end;
                58:
                    begin
                        Cyc += 13;
                        ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if ea >= 32768 then rA := Mem[ea + 1] else if ea < 16384 then rA := Rom[RomBase + ea + 1] else rA := ReadMem(ea);
                    end;
                59:
                    begin
                        Cyc += 6;
                        rSP := (rSP + 65535) mod 65536;
                    end;
                60:
                    begin
                        Cyc += 4;
                        if rA = 255 then rA := 0 else rA += 1;
                        rF := (rF mod 2) + SZHVinc[rA + 1];
                    end;
                61:
                    begin
                        Cyc += 4;
                        if rA = 0 then rA := 255 else rA -= 1;
                        rF := (rF mod 2) + SZHVdec[rA + 1];
                    end;
                62:
                    begin
                        Cyc += 7;
                        rA := Rom[RomBase + rPC + 1];
                        rPC += 1;
                    end;
                63:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        rF := AndT[rF * 256 + 197] + c * 16 + (1 - c) + XYT[rA + 1];
                    end;
                64:
                    Cyc += 4;
                65:
                    begin
                        Cyc += 4;
                        rB := rC;
                    end;
                66:
                    begin
                        Cyc += 4;
                        rB := rD;
                    end;
                67:
                    begin
                        Cyc += 4;
                        rB := rE;
                    end;
                68:
                    begin
                        Cyc += 4;
                        rB := rH;
                    end;
                69:
                    begin
                        Cyc += 4;
                        rB := rL;
                    end;
                70:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rB := Mem[ea + 1] else if ea < 16384 then rB := Rom[RomBase + ea + 1] else rB := ReadMem(ea);
                    end;
                71:
                    begin
                        Cyc += 4;
                        rB := rA;
                    end;
                72:
                    begin
                        Cyc += 4;
                        rC := rB;
                    end;
                73:
                    Cyc += 4;
                74:
                    begin
                        Cyc += 4;
                        rC := rD;
                    end;
                75:
                    begin
                        Cyc += 4;
                        rC := rE;
                    end;
                76:
                    begin
                        Cyc += 4;
                        rC := rH;
                    end;
                77:
                    begin
                        Cyc += 4;
                        rC := rL;
                    end;
                78:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rC := Mem[ea + 1] else if ea < 16384 then rC := Rom[RomBase + ea + 1] else rC := ReadMem(ea);
                    end;
                79:
                    begin
                        Cyc += 4;
                        rC := rA;
                    end;
                80:
                    begin
                        Cyc += 4;
                        rD := rB;
                    end;
                81:
                    begin
                        Cyc += 4;
                        rD := rC;
                    end;
                82:
                    Cyc += 4;
                83:
                    begin
                        Cyc += 4;
                        rD := rE;
                    end;
                84:
                    begin
                        Cyc += 4;
                        rD := rH;
                    end;
                85:
                    begin
                        Cyc += 4;
                        rD := rL;
                    end;
                86:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rD := Mem[ea + 1] else if ea < 16384 then rD := Rom[RomBase + ea + 1] else rD := ReadMem(ea);
                    end;
                87:
                    begin
                        Cyc += 4;
                        rD := rA;
                    end;
                88:
                    begin
                        Cyc += 4;
                        rE := rB;
                    end;
                89:
                    begin
                        Cyc += 4;
                        rE := rC;
                    end;
                90:
                    begin
                        Cyc += 4;
                        rE := rD;
                    end;
                91:
                    Cyc += 4;
                92:
                    begin
                        Cyc += 4;
                        rE := rH;
                    end;
                93:
                    begin
                        Cyc += 4;
                        rE := rL;
                    end;
                94:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rE := Mem[ea + 1] else if ea < 16384 then rE := Rom[RomBase + ea + 1] else rE := ReadMem(ea);
                    end;
                95:
                    begin
                        Cyc += 4;
                        rE := rA;
                    end;
                96:
                    begin
                        Cyc += 4;
                        rH := rB;
                    end;
                97:
                    begin
                        Cyc += 4;
                        rH := rC;
                    end;
                98:
                    begin
                        Cyc += 4;
                        rH := rD;
                    end;
                99:
                    begin
                        Cyc += 4;
                        rH := rE;
                    end;
                100:
                    Cyc += 4;
                101:
                    begin
                        Cyc += 4;
                        rH := rL;
                    end;
                102:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rH := Mem[ea + 1] else if ea < 16384 then rH := Rom[RomBase + ea + 1] else rH := ReadMem(ea);
                    end;
                103:
                    begin
                        Cyc += 4;
                        rH := rA;
                    end;
                104:
                    begin
                        Cyc += 4;
                        rL := rB;
                    end;
                105:
                    begin
                        Cyc += 4;
                        rL := rC;
                    end;
                106:
                    begin
                        Cyc += 4;
                        rL := rD;
                    end;
                107:
                    begin
                        Cyc += 4;
                        rL := rE;
                    end;
                108:
                    begin
                        Cyc += 4;
                        rL := rH;
                    end;
                109:
                    Cyc += 4;
                110:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rL := Mem[ea + 1] else if ea < 16384 then rL := Rom[RomBase + ea + 1] else rL := ReadMem(ea);
                    end;
                111:
                    begin
                        Cyc += 4;
                        rL := rA;
                    end;
                112:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rB then begin Mem[ea + 1] := rB; WrCnt += 1; end; end else WriteMem(ea, rB);
                    end;
                113:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rC then begin Mem[ea + 1] := rC; WrCnt += 1; end; end else WriteMem(ea, rC);
                    end;
                114:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rD then begin Mem[ea + 1] := rD; WrCnt += 1; end; end else WriteMem(ea, rD);
                    end;
                115:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rE then begin Mem[ea + 1] := rE; WrCnt += 1; end; end else WriteMem(ea, rE);
                    end;
                116:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rH then begin Mem[ea + 1] := rH; WrCnt += 1; end; end else WriteMem(ea, rH);
                    end;
                117:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rL then begin Mem[ea + 1] := rL; WrCnt += 1; end; end else WriteMem(ea, rL);
                    end;
                118:
                    begin
                        Cyc += 4;
                        rPC -= 1;
                        Halted := true;
                        IdleCycles[CpuNo] += RunTarget - Cyc;
                        Cyc := RunTarget;
                    end;
                119:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rA then begin Mem[ea + 1] := rA; WrCnt += 1; end; end else WriteMem(ea, rA);
                    end;
                120:
                    begin
                        Cyc += 4;
                        rA := rB;
                    end;
                121:
                    begin
                        Cyc += 4;
                        rA := rC;
                    end;
                122:
                    begin
                        Cyc += 4;
                        rA := rD;
                    end;
                123:
                    begin
                        Cyc += 4;
                        rA := rE;
                    end;
                124:
                    begin
                        Cyc += 4;
                        rA := rH;
                    end;
                125:
                    begin
                        Cyc += 4;
                        rA := rL;
                    end;
                126:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then rA := Mem[ea + 1] else if ea < 16384 then rA := Rom[RomBase + ea + 1] else rA := ReadMem(ea);
                    end;
                127:
                    Cyc += 4;
                128:
                    begin
                        Cyc += 4;
                        t := rA + rB;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rB mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rB < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                129:
                    begin
                        Cyc += 4;
                        t := rA + rC;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rC mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rC < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                130:
                    begin
                        Cyc += 4;
                        t := rA + rD;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rD mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rD < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                131:
                    begin
                        Cyc += 4;
                        t := rA + rE;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rE mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rE < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                132:
                    begin
                        Cyc += 4;
                        t := rA + rH;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rH mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rH < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                133:
                    begin
                        Cyc += 4;
                        t := rA + rL;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rL mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rL < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                134:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        t := rA + v;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (v mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                135:
                    begin
                        Cyc += 4;
                        t := rA + rA;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rA mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (rA < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                136:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rB + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rB mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rB < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                137:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rC + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rC mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rC < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                138:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rD + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rD mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rD < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                139:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rE + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rE mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rE < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                140:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rH + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rH mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rH < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                141:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rL + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rL mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rL < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                142:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        c := rF mod 2;
                        t := rA + v + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (v mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                143:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA + rA + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (rA mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (rA < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                144:
                    begin
                        Cyc += 4;
                        t := rA - rB;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rB mod 16) then rF += 16;
                        if ((rA < 128) <> (rB < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                145:
                    begin
                        Cyc += 4;
                        t := rA - rC;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rC mod 16) then rF += 16;
                        if ((rA < 128) <> (rC < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                146:
                    begin
                        Cyc += 4;
                        t := rA - rD;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rD mod 16) then rF += 16;
                        if ((rA < 128) <> (rD < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                147:
                    begin
                        Cyc += 4;
                        t := rA - rE;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rE mod 16) then rF += 16;
                        if ((rA < 128) <> (rE < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                148:
                    begin
                        Cyc += 4;
                        t := rA - rH;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rH mod 16) then rF += 16;
                        if ((rA < 128) <> (rH < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                149:
                    begin
                        Cyc += 4;
                        t := rA - rL;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rL mod 16) then rF += 16;
                        if ((rA < 128) <> (rL < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                150:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        t := rA - v;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (v mod 16) then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                151:
                    begin
                        Cyc += 4;
                        t := rA - rA;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (rA mod 16) then rF += 16;
                        if ((rA < 128) <> (rA < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                152:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rB - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rB mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rB < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                153:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rC - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rC mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rC < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                154:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rD - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rD mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rD < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                155:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rE - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rE mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rE < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                156:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rH - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rH mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rH < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                157:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rL - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rL mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rL < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                158:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        c := rF mod 2;
                        t := rA - v - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (v mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                159:
                    begin
                        Cyc += 4;
                        c := rF mod 2;
                        t := rA - rA - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (rA mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (rA < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                160:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rB + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                161:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rC + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                162:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rD + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                163:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rE + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                164:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rH + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                165:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rL + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                166:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        rA := AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                167:
                    begin
                        Cyc += 4;
                        rA := AndT[rA * 256 + rA + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                168:
                    begin
                        Cyc += 4;
                        rA := rA + rB - 2 * AndT[rA * 256 + rB + 1];
                        rF := SZP[rA + 1];
                    end;
                169:
                    begin
                        Cyc += 4;
                        rA := rA + rC - 2 * AndT[rA * 256 + rC + 1];
                        rF := SZP[rA + 1];
                    end;
                170:
                    begin
                        Cyc += 4;
                        rA := rA + rD - 2 * AndT[rA * 256 + rD + 1];
                        rF := SZP[rA + 1];
                    end;
                171:
                    begin
                        Cyc += 4;
                        rA := rA + rE - 2 * AndT[rA * 256 + rE + 1];
                        rF := SZP[rA + 1];
                    end;
                172:
                    begin
                        Cyc += 4;
                        rA := rA + rH - 2 * AndT[rA * 256 + rH + 1];
                        rF := SZP[rA + 1];
                    end;
                173:
                    begin
                        Cyc += 4;
                        rA := rA + rL - 2 * AndT[rA * 256 + rL + 1];
                        rF := SZP[rA + 1];
                    end;
                174:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        rA := rA + v - 2 * AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1];
                    end;
                175:
                    begin
                        Cyc += 4;
                        rA := rA + rA - 2 * AndT[rA * 256 + rA + 1];
                        rF := SZP[rA + 1];
                    end;
                176:
                    begin
                        Cyc += 4;
                        rA := rA + rB - AndT[rA * 256 + rB + 1];
                        rF := SZP[rA + 1];
                    end;
                177:
                    begin
                        Cyc += 4;
                        rA := rA + rC - AndT[rA * 256 + rC + 1];
                        rF := SZP[rA + 1];
                    end;
                178:
                    begin
                        Cyc += 4;
                        rA := rA + rD - AndT[rA * 256 + rD + 1];
                        rF := SZP[rA + 1];
                    end;
                179:
                    begin
                        Cyc += 4;
                        rA := rA + rE - AndT[rA * 256 + rE + 1];
                        rF := SZP[rA + 1];
                    end;
                180:
                    begin
                        Cyc += 4;
                        rA := rA + rH - AndT[rA * 256 + rH + 1];
                        rF := SZP[rA + 1];
                    end;
                181:
                    begin
                        Cyc += 4;
                        rA := rA + rL - AndT[rA * 256 + rL + 1];
                        rF := SZP[rA + 1];
                    end;
                182:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        rA := rA + v - AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1];
                    end;
                183:
                    begin
                        Cyc += 4;
                        rA := rA + rA - AndT[rA * 256 + rA + 1];
                        rF := SZP[rA + 1];
                    end;
                184:
                    begin
                        Cyc += 4;
                        t := rA - rB;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rB + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rB + 1];
                        if (rA mod 16) < (rB mod 16) then rF += 16;
                        if ((rA < 128) <> (rB < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                185:
                    begin
                        Cyc += 4;
                        t := rA - rC;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rC + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rC + 1];
                        if (rA mod 16) < (rC mod 16) then rF += 16;
                        if ((rA < 128) <> (rC < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                186:
                    begin
                        Cyc += 4;
                        t := rA - rD;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rD + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rD + 1];
                        if (rA mod 16) < (rD mod 16) then rF += 16;
                        if ((rA < 128) <> (rD < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                187:
                    begin
                        Cyc += 4;
                        t := rA - rE;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rE + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rE + 1];
                        if (rA mod 16) < (rE mod 16) then rF += 16;
                        if ((rA < 128) <> (rE < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                188:
                    begin
                        Cyc += 4;
                        t := rA - rH;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rH + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rH + 1];
                        if (rA mod 16) < (rH mod 16) then rF += 16;
                        if ((rA < 128) <> (rH < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                189:
                    begin
                        Cyc += 4;
                        t := rA - rL;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rL + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rL + 1];
                        if (rA mod 16) < (rL mod 16) then rF += 16;
                        if ((rA < 128) <> (rL < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                190:
                    begin
                        Cyc += 7;
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        t := rA - v;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[v + 1]; end else rF := SZ0[t + 1] + 2 + XYT[v + 1];
                        if (rA mod 16) < (v mod 16) then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                191:
                    begin
                        Cyc += 4;
                        t := rA - rA;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[rA + 1]; end else rF := SZ0[t + 1] + 2 + XYT[rA + 1];
                        if (rA mod 16) < (rA mod 16) then rF += 16;
                        if ((rA < 128) <> (rA < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                192:
                    begin
                        Cyc += 5;
                        if (rF mod 128) < 64 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                193:
                    begin
                        Cyc += 10;
                        if rSP >= 32768 then rC := Mem[rSP + 1] else if rSP < 16384 then rC := Rom[RomBase + rSP + 1] else rC := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        if rSP >= 32768 then rB := Mem[rSP + 1] else if rSP < 16384 then rB := Rom[RomBase + rSP + 1] else rB := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                    end;
                194:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 128) < 64 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                195:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (n < rPC) and (n >= rPC - 20) then begin
                            rPC := n;
                            if (n = rPC - 3) or ((n = rPC - 6) and (Rom[RomBase + n + 1] = 49)) then begin
                                SelfIdle[CpuNo] := true;
                                IdleCycles[CpuNo] += RunTarget - Cyc;
                                Cyc := RunTarget;
                            end else
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                        end else
                            rPC := n;
                    end;
                196:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 128) < 64 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                197:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rB then begin Mem[rSP + 1] := rB; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rB);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rC then begin Mem[rSP + 1] := rC; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rC);
                    end;
                198:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        t := rA + v;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (v mod 16) > 15 then rF += 16;
                        if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                199:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 0;
                    end;
                200:
                    begin
                        Cyc += 5;
                        if (rF mod 128) >= 64 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                201:
                    begin
                        Cyc += 10;
                        if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        rPC := t * 256 + n;
                    end;
                202:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 128) >= 64 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                203:
                    ExecCB();
                204:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 128) >= 64 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                205:
                    begin
                        Cyc += 17;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := n;
                    end;
                206:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        c := rF mod 2;
                        t := rA + v + c;
                        if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                        if (rA mod 16) + (v mod 16) + c > 15 then rF += 16;
                        if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                207:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 8;
                    end;
                208:
                    begin
                        Cyc += 5;
                        if (rF mod 2) = 0 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                209:
                    begin
                        Cyc += 10;
                        if rSP >= 32768 then rE := Mem[rSP + 1] else if rSP < 16384 then rE := Rom[RomBase + rSP + 1] else rE := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        if rSP >= 32768 then rD := Mem[rSP + 1] else if rSP < 16384 then rD := Rom[RomBase + rSP + 1] else rD := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                    end;
                210:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 2) = 0 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                211:
                    begin
                        Cyc += 11;
                        rPC += 1;
                    end;
                212:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 2) = 0 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                213:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rD then begin Mem[rSP + 1] := rD; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rD);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rE then begin Mem[rSP + 1] := rE; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rE);
                    end;
                214:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        t := rA - v;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) < (v mod 16) then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                215:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 16;
                    end;
                216:
                    begin
                        Cyc += 5;
                        if (rF mod 2) = 1 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                217:
                    begin
                        Cyc += 4;
                        t := rB * 256 + rC;
                        rB := BC2 div 256;
                        rC := BC2 mod 256;
                        BC2 := t;
                        t := rD * 256 + rE;
                        rD := DE2 div 256;
                        rE := DE2 mod 256;
                        DE2 := t;
                        t := rH * 256 + rL;
                        rH := HL2 div 256;
                        rL := HL2 mod 256;
                        HL2 := t;
                    end;
                218:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 2) = 1 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                219:
                    begin
                        Cyc += 11;
                        rPC += 1;
                        rA := 255;
                    end;
                220:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 2) = 1 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                221:
                    ExecXY(false);
                222:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        c := rF mod 2;
                        t := rA - v - c;
                        if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                        if (rA mod 16) - (v mod 16) - c < 0 then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                        rA := t;
                    end;
                223:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 24;
                    end;
                224:
                    begin
                        Cyc += 5;
                        if (rF mod 8) < 4 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                225:
                    begin
                        Cyc += 10;
                        if rSP >= 32768 then rL := Mem[rSP + 1] else if rSP < 16384 then rL := Rom[RomBase + rSP + 1] else rL := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        if rSP >= 32768 then rH := Mem[rSP + 1] else if rSP < 16384 then rH := Rom[RomBase + rSP + 1] else rH := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                    end;
                226:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 8) < 4 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                227:
                    begin
                        Cyc += 19;
                        if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                        ea := (rSP + 1) mod 65536;
                        if ea >= 32768 then t := Mem[ea + 1] else if ea < 16384 then t := Rom[RomBase + ea + 1] else t := ReadMem(ea);
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rL then begin Mem[rSP + 1] := rL; WrCnt += 1; end; end else WriteMem(rSP, rL);
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rH then begin Mem[ea + 1] := rH; WrCnt += 1; end; end else WriteMem(ea, rH);
                        rH := t;
                        rL := n;
                    end;
                228:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 8) < 4 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                229:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rH then begin Mem[rSP + 1] := rH; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rH);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rL then begin Mem[rSP + 1] := rL; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rL);
                    end;
                230:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        rA := AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1] + 16;
                    end;
                231:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 32;
                    end;
                232:
                    begin
                        Cyc += 5;
                        if (rF mod 8) >= 4 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                233:
                    begin
                        Cyc += 4;
                        rPC := rH * 256 + rL;
                    end;
                234:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 8) >= 4 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                235:
                    begin
                        Cyc += 4;
                        t := rD;
                        rD := rH;
                        rH := t;
                        t := rE;
                        rE := rL;
                        rL := t;
                    end;
                236:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if (rF mod 8) >= 4 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                237:
                    ExecED();
                238:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        rA := rA + v - 2 * AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1];
                    end;
                239:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 40;
                    end;
                240:
                    begin
                        Cyc += 5;
                        if rF < 128 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                241:
                    begin
                        Cyc += 10;
                        if rSP >= 32768 then rF := Mem[rSP + 1] else if rSP < 16384 then rF := Rom[RomBase + rSP + 1] else rF := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                        if rSP >= 32768 then rA := Mem[rSP + 1] else if rSP < 16384 then rA := Rom[RomBase + rSP + 1] else rA := ReadMem(rSP);
                        rSP := (rSP + 1) mod 65536;
                    end;
                242:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if rF < 128 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                243:
                    begin
                        Cyc += 4;
                        IFF1 := false;
                        IFF2 := false;
                    end;
                244:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if rF < 128 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                245:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rA then begin Mem[rSP + 1] := rA; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rA);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rF then begin Mem[rSP + 1] := rF; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rF);
                    end;
                246:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        rA := rA + v - AndT[rA * 256 + v + 1];
                        rF := SZP[rA + 1];
                    end;
                247:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 48;
                    end;
                248:
                    begin
                        Cyc += 5;
                        if rF >= 128 then begin
                            if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                            rSP := (rSP + 1) mod 65536;
                            rPC := t * 256 + n;
                            Cyc += 6;
                        end;
                    end;
                249:
                    begin
                        Cyc += 6;
                        rSP := rH * 256 + rL;
                    end;
                250:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if rF >= 128 then begin
                            if (n < rPC) and (n >= rPC - 20) then begin
                                rPC := n;
                                if rPC <> IdleT then begin
                                    IdleT := rPC;
                                    IdleW := -1;
                                end else
                                    IdleCheck();
                            end else
                                rPC := n;
                        end;
                    end;
                251:
                    begin
                        Cyc += 4;
                        IFF1 := true;
                        IFF2 := true;
                        EiDelay := true;
                        IntPending := true;
                    end;
                252:
                    begin
                        Cyc += 10;
                        n := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                        rPC += 2;
                        if rF >= 128 then begin
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                            rSP := (rSP + 65535) mod 65536;
                            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                            rPC := n;
                            Cyc += 7;
                        end;
                    end;
                253:
                    ExecXY(true);
                254:
                    begin
                        Cyc += 7;
                        v := Rom[RomBase + rPC + 1];
                        rPC += 1;
                        t := rA - v;
                        if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[v + 1]; end else rF := SZ0[t + 1] + 2 + XYT[v + 1];
                        if (rA mod 16) < (v mod 16) then rF += 16;
                        if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    end;
                255:
                    begin
                        Cyc += 11;
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                        rSP := (rSP + 65535) mod 65536;
                        if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                        rPC := 56;
                    end;
            end;
        end;
    end;

    /// <summary>Takes a pending NMI or IRQ (IM 1, or IM 2 with 255 on the data bus).</summary>
    local procedure CheckInterrupt()
    var
        ea: Integer;
    begin
        if NmiPending[CpuNo] then begin
            NmiPending[CpuNo] := false;
            if Halted then begin
                Halted := false;
                rPC += 1;
            end;
            IFF1 := false;
            rSP := (rSP + 65535) mod 65536;
            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
            rSP := (rSP + 65535) mod 65536;
            if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
            rPC := 102;
            Cyc += 11;
        end else
            if EiDelay then
                // the instruction after EI runs before an interrupt is taken
                EiDelay := false
            else
                if IFF1 and IrqLine[CpuNo] then begin
                    if Halted then begin
                        Halted := false;
                        rPC += 1;
                    end;
                    IFF1 := false;
                    IFF2 := false;
                    rSP := (rSP + 65535) mod 65536;
                    if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC div 256 then begin Mem[rSP + 1] := rPC div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC div 256);
                    rSP := (rSP + 65535) mod 65536;
                    if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> rPC mod 256 then begin Mem[rSP + 1] := rPC mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, rPC mod 256);
                    if IntMode = 2 then begin
                        ea := rI * 256 + 255;
                        rPC := ReadMem(ea) + 256 * ReadMem((ea + 1) mod 65536);
                        Cyc += 19;
                    end else begin
                        rPC := 56;
                        Cyc += 13;
                    end;
                end;
        IntPending := NmiPending[CpuNo] or EiDelay or (IFF1 and IrqLine[CpuNo]);
    end;

    local procedure ExecCB()
    var
        op: Integer;
        r: Integer;
        b: Integer;
        m: Integer;
        v: Integer;
        ea: Integer;
    begin
        op := Rom[RomBase + rPC + 1];
        rPC += 1;
        r := op mod 8;
        case r of
            0: v := rB;
            1: v := rC;
            2: v := rD;
            3: v := rE;
            4: v := rH;
            5: v := rL;
            6: begin
                ea := rH * 256 + rL;
                if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
            end;
            7: v := rA;
        end;
        b := (op div 8) mod 8;
        case op div 64 of
            0: v := RotOp(b, v);
            1: begin
                // BIT: Z (and P/V) when the bit is clear, S for a set bit 7, H set, C kept
                if ((v div Pow2[b + 1]) mod 2) = 0 then
                    rF := (rF mod 2) + 84 + XYT[v + 1]
                else
                    if b = 7 then rF := (rF mod 2) + 144 + XYT[v + 1] else rF := (rF mod 2) + 16 + XYT[v + 1];
                if r = 6 then Cyc += 12 else Cyc += 8;
                exit;
            end;
            2: begin
                m := Pow2[b + 1];
                if ((v div m) mod 2) = 1 then v -= m;
            end;
            3: begin
                m := Pow2[b + 1];
                if ((v div m) mod 2) = 0 then v += m;
            end;
        end;
        case r of
            0: rB := v;
            1: rC := v;
            2: rD := v;
            3: rE := v;
            4: rH := v;
            5: rL := v;
            6: begin
                if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                Cyc += 15;
                exit;
            end;
            7: rA := v;
        end;
        Cyc += 8;
    end;

    local procedure ExecXYCB(ea: Integer)
    var
        op: Integer;
        r: Integer;
        b: Integer;
        m: Integer;
        v: Integer;
    begin
        op := Rom[RomBase + rPC + 1];
        rPC += 1;
        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
        r := op mod 8;
        b := (op div 8) mod 8;
        case op div 64 of
            0: v := RotOp(b, v);
            1: begin
                if ((v div Pow2[b + 1]) mod 2) = 0 then
                    rF := (rF mod 2) + 84 + XYT[v + 1]
                else
                    if b = 7 then rF := (rF mod 2) + 144 + XYT[v + 1] else rF := (rF mod 2) + 16 + XYT[v + 1];
                Cyc += 20;
                exit;
            end;
            2: begin
                m := Pow2[b + 1];
                if ((v div m) mod 2) = 1 then v -= m;
            end;
            3: begin
                m := Pow2[b + 1];
                if ((v div m) mod 2) = 0 then v += m;
            end;
        end;
        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
        // undocumented: the result is also copied to a register
        case r of
            0: rB := v;
            1: rC := v;
            2: rD := v;
            3: rE := v;
            4: rH := v;
            5: rL := v;
            7: rA := v;
        end;
        Cyc += 23;
    end;

    local procedure ExecED()
    var
        op: Integer;
        n: Integer;
        t: Integer;
        v: Integer;
        c: Integer;
        w: Integer;
        ea: Integer;
        hl: Integer;
    begin
        op := Rom[RomBase + rPC + 1];
        rPC += 1;
        case op of
            64:
                begin
                    Cyc += 12;
                    rB := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            65:
                Cyc += 12;
            66:
                begin
                    Cyc += 15;
                    w := rB * 256 + rC;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl - w - c;
                    rF := 2;
                    if t < 0 then begin t += 65536; rF += 1; end;
                    if (hl mod 4096) - (w mod 4096) - c < 0 then rF += 16;
                    if ((hl < 32768) <> (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            67:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rC then begin Mem[ea + 1] := rC; WrCnt += 1; end; end else WriteMem(ea, rC);
                    ea := (ea + 1) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rB then begin Mem[ea + 1] := rB; WrCnt += 1; end; end else WriteMem(ea, rB);
                end;
            68:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            69:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            70:
                begin
                    Cyc += 8;
                    IntMode := 0;
                end;
            71:
                begin
                    Cyc += 9;
                    rI := rA;
                end;
            72:
                begin
                    Cyc += 12;
                    rC := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            73:
                Cyc += 12;
            74:
                begin
                    Cyc += 15;
                    w := rB * 256 + rC;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl + w + c;
                    rF := 0;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    if (hl mod 4096) + (w mod 4096) + c > 4095 then rF += 16;
                    if ((hl < 32768) = (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            75:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if ea >= 32768 then rC := Mem[ea + 1] else if ea < 16384 then rC := Rom[RomBase + ea + 1] else rC := ReadMem(ea);
                    ea := (ea + 1) mod 65536;
                    if ea >= 32768 then rB := Mem[ea + 1] else if ea < 16384 then rB := Rom[RomBase + ea + 1] else rB := ReadMem(ea);
                end;
            76:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            77:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            78:
                begin
                    Cyc += 8;
                    IntMode := 0;
                end;
            79:
                begin
                    Cyc += 9;
                    rR := (rA mod 128 - (Cyc div 4) mod 128 + 128) mod 128;
                    rR7 := rA - rA mod 128;
                end;
            80:
                begin
                    Cyc += 12;
                    rD := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            81:
                Cyc += 12;
            82:
                begin
                    Cyc += 15;
                    w := rD * 256 + rE;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl - w - c;
                    rF := 2;
                    if t < 0 then begin t += 65536; rF += 1; end;
                    if (hl mod 4096) - (w mod 4096) - c < 0 then rF += 16;
                    if ((hl < 32768) <> (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            83:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rE then begin Mem[ea + 1] := rE; WrCnt += 1; end; end else WriteMem(ea, rE);
                    ea := (ea + 1) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rD then begin Mem[ea + 1] := rD; WrCnt += 1; end; end else WriteMem(ea, rD);
                end;
            84:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            85:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            86:
                begin
                    Cyc += 8;
                    IntMode := 1;
                end;
            87:
                begin
                    Cyc += 9;
                    rA := rI;
                    rF := (rF mod 2) + SZ[rA + 1];
                    if IFF2 then rF += 4;
                end;
            88:
                begin
                    Cyc += 12;
                    rE := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            89:
                Cyc += 12;
            90:
                begin
                    Cyc += 15;
                    w := rD * 256 + rE;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl + w + c;
                    rF := 0;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    if (hl mod 4096) + (w mod 4096) + c > 4095 then rF += 16;
                    if ((hl < 32768) = (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            91:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if ea >= 32768 then rE := Mem[ea + 1] else if ea < 16384 then rE := Rom[RomBase + ea + 1] else rE := ReadMem(ea);
                    ea := (ea + 1) mod 65536;
                    if ea >= 32768 then rD := Mem[ea + 1] else if ea < 16384 then rD := Rom[RomBase + ea + 1] else rD := ReadMem(ea);
                end;
            92:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            93:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            94:
                begin
                    Cyc += 8;
                    IntMode := 2;
                end;
            95:
                begin
                    Cyc += 9;
                    rA := (Cyc div 4 + rR) mod 128 + rR7;
                    rF := (rF mod 2) + SZ[rA + 1];
                    if IFF2 then rF += 4;
                end;
            96:
                begin
                    Cyc += 12;
                    rH := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            97:
                Cyc += 12;
            98:
                begin
                    Cyc += 15;
                    w := rH * 256 + rL;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl - w - c;
                    rF := 2;
                    if t < 0 then begin t += 65536; rF += 1; end;
                    if (hl mod 4096) - (w mod 4096) - c < 0 then rF += 16;
                    if ((hl < 32768) <> (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            99:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rL then begin Mem[ea + 1] := rL; WrCnt += 1; end; end else WriteMem(ea, rL);
                    ea := (ea + 1) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rH then begin Mem[ea + 1] := rH; WrCnt += 1; end; end else WriteMem(ea, rH);
                end;
            100:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            101:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            102:
                begin
                    Cyc += 8;
                    IntMode := 0;
                end;
            103:
                begin
                    Cyc += 18;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then n := Mem[ea + 1] else if ea < 16384 then n := Rom[RomBase + ea + 1] else n := ReadMem(ea);
                    v := n div 16 + (rA mod 16) * 16;
                    rA := (rA div 16) * 16 + n mod 16;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    rF := (rF mod 2) + SZP[rA + 1];
                end;
            104:
                begin
                    Cyc += 12;
                    rL := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            105:
                Cyc += 12;
            106:
                begin
                    Cyc += 15;
                    w := rH * 256 + rL;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl + w + c;
                    rF := 0;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    if (hl mod 4096) + (w mod 4096) + c > 4095 then rF += 16;
                    if ((hl < 32768) = (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            107:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if ea >= 32768 then rL := Mem[ea + 1] else if ea < 16384 then rL := Rom[RomBase + ea + 1] else rL := ReadMem(ea);
                    ea := (ea + 1) mod 65536;
                    if ea >= 32768 then rH := Mem[ea + 1] else if ea < 16384 then rH := Rom[RomBase + ea + 1] else rH := ReadMem(ea);
                end;
            108:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            109:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            110:
                begin
                    Cyc += 8;
                    IntMode := 0;
                end;
            111:
                begin
                    Cyc += 18;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then n := Mem[ea + 1] else if ea < 16384 then n := Rom[RomBase + ea + 1] else n := ReadMem(ea);
                    v := (n mod 16) * 16 + rA mod 16;
                    rA := (rA div 16) * 16 + n div 16;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    rF := (rF mod 2) + SZP[rA + 1];
                end;
            112:
                begin
                    Cyc += 12;
                    rF := (rF mod 2) + SZP[256];
                end;
            113:
                Cyc += 12;
            114:
                begin
                    Cyc += 15;
                    w := rSP;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl - w - c;
                    rF := 2;
                    if t < 0 then begin t += 65536; rF += 1; end;
                    if (hl mod 4096) - (w mod 4096) - c < 0 then rF += 16;
                    if ((hl < 32768) <> (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            115:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rSP mod 256 then begin Mem[ea + 1] := rSP mod 256; WrCnt += 1; end; end else WriteMem(ea, rSP mod 256);
                    ea := (ea + 1) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rSP div 256 then begin Mem[ea + 1] := rSP div 256; WrCnt += 1; end; end else WriteMem(ea, rSP div 256);
                end;
            116:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            117:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            118:
                begin
                    Cyc += 8;
                    IntMode := 1;
                end;
            120:
                begin
                    Cyc += 12;
                    rA := 255;
                    rF := (rF mod 2) + SZP[256];
                end;
            121:
                Cyc += 12;
            122:
                begin
                    Cyc += 15;
                    w := rSP;
                    hl := rH * 256 + rL;
                    c := rF mod 2;
                    t := hl + w + c;
                    rF := 0;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    if (hl mod 4096) + (w mod 4096) + c > 4095 then rF += 16;
                    if ((hl < 32768) = (w < 32768)) and ((hl < 32768) <> (t < 32768)) then rF += 4;
                    rH := t div 256;
                    rL := t mod 256;
                    rF += XYT[rH + 1];
                    if rH >= 128 then rF += 128;
                    if t = 0 then rF += 64;
                end;
            123:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if ea >= 32768 then n := Mem[ea + 1] else if ea < 16384 then n := Rom[RomBase + ea + 1] else n := ReadMem(ea);
                    ea := (ea + 1) mod 65536;
                    if ea >= 32768 then t := Mem[ea + 1] else if ea < 16384 then t := Rom[RomBase + ea + 1] else t := ReadMem(ea);
                    rSP := t * 256 + n;
                end;
            124:
                begin
                    Cyc += 8;
                    v := rA;
                    rA := 0;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            125:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    rPC := t * 256 + n;
                    IFF1 := IFF2;
                    if IFF1 then IntPending := true;
                end;
            126:
                begin
                    Cyc += 8;
                    IntMode := 2;
                end;
            160:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    ea := rD * 256 + rE;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    if rE < 255 then rE += 1 else begin rE := 0; rD := (rD + 1) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    n := rA + v;
                    rF := AndT[rF * 256 + 194];
                    if (n mod 4) >= 2 then rF += 32;
                    if (n mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then rF += 4;
                end;
            161:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then t += 256;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    rF := (rF mod 2) + SZ0[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then begin rF += 16; t := (t + 255) mod 256; end;
                    if (t mod 4) >= 2 then rF += 32;
                    if (t mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                    end;
                end;
            162:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> 255 then begin Mem[ea + 1] := 255; WrCnt += 1; end; end else WriteMem(ea, 255);
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                end;
            163:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                end;
            168:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    ea := rD * 256 + rE;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    if rE > 0 then rE -= 1 else begin rE := 255; rD := (rD + 255) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    n := rA + v;
                    rF := AndT[rF * 256 + 194];
                    if (n mod 4) >= 2 then rF += 32;
                    if (n mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then rF += 4;
                end;
            169:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then t += 256;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    rF := (rF mod 2) + SZ0[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then begin rF += 16; t := (t + 255) mod 256; end;
                    if (t mod 4) >= 2 then rF += 32;
                    if (t mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                    end;
                end;
            170:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> 255 then begin Mem[ea + 1] := 255; WrCnt += 1; end; end else WriteMem(ea, 255);
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                end;
            171:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                end;
            176:
                begin
                    repeat
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        ea := rD * 256 + rE;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                        if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                        if rE < 255 then rE += 1 else begin rE := 0; rD := (rD + 1) mod 256; end;
                        if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                        Cyc += 21;
                    until ((rB = 0) and (rC = 0)) or (Cyc >= RunTarget);
                    n := rA + v;
                    rF := AndT[rF * 256 + 194];
                    if (n mod 4) >= 2 then rF += 32;
                    if (n mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                        rPC -= 2;
                    end else
                        Cyc -= 5;
                end;
            177:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then t += 256;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    rF := (rF mod 2) + SZ0[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then begin rF += 16; t := (t + 255) mod 256; end;
                    if (t mod 4) >= 2 then rF += 32;
                    if (t mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                        if (rF mod 128) < 64 then begin
                            rPC -= 2;
                            Cyc += 5;
                        end;
                    end;
                end;
            178:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> 255 then begin Mem[ea + 1] := 255; WrCnt += 1; end; end else WriteMem(ea, 255);
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                    if rB <> 0 then begin
                        rPC -= 2;
                        Cyc += 5;
                    end;
                end;
            179:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL < 255 then rL += 1 else begin rL := 0; rH := (rH + 1) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                    if rB <> 0 then begin
                        rPC -= 2;
                        Cyc += 5;
                    end;
                end;
            184:
                begin
                    repeat
                        ea := rH * 256 + rL;
                        if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                        ea := rD * 256 + rE;
                        if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                        if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                        if rE > 0 then rE -= 1 else begin rE := 255; rD := (rD + 255) mod 256; end;
                        if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                        Cyc += 21;
                    until ((rB = 0) and (rC = 0)) or (Cyc >= RunTarget);
                    n := rA + v;
                    rF := AndT[rF * 256 + 194];
                    if (n mod 4) >= 2 then rF += 32;
                    if (n mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                        rPC -= 2;
                    end else
                        Cyc -= 5;
                end;
            185:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then t += 256;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    if rC > 0 then rC -= 1 else begin rC := 255; rB := (rB + 255) mod 256; end;
                    rF := (rF mod 2) + SZ0[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then begin rF += 16; t := (t + 255) mod 256; end;
                    if (t mod 4) >= 2 then rF += 32;
                    if (t mod 16) >= 8 then rF += 8;
                    if (rB <> 0) or (rC <> 0) then begin
                        rF += 4;
                        if (rF mod 128) < 64 then begin
                            rPC -= 2;
                            Cyc += 5;
                        end;
                    end;
                end;
            186:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> 255 then begin Mem[ea + 1] := 255; WrCnt += 1; end; end else WriteMem(ea, 255);
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                    if rB <> 0 then begin
                        rPC -= 2;
                        Cyc += 5;
                    end;
                end;
            187:
                begin
                    Cyc += 16;
                    ea := rH * 256 + rL;
                    if rB = 0 then rB := 255 else rB -= 1;
                    if rL > 0 then rL -= 1 else begin rL := 255; rH := (rH + 255) mod 256; end;
                    rF := SZ[rB + 1] + 2;
                    if rB <> 0 then begin
                        rPC -= 2;
                        Cyc += 5;
                    end;
                end;
            else
                Cyc += 8;
        end;
    end;

    /// <summary>
    /// Executes a DD (IX) or FD (IY) prefixed opcode. When the opcode does not use HL, H or L the prefix has no
    /// effect: then the opcode runs as an unprefixed one in the next step of Execute.
    /// </summary>
    local procedure ExecXY(IsIY: Boolean)
    var
        op: Integer;
        n: Integer;
        t: Integer;
        v: Integer;
        c: Integer;
        d: Integer;
        w: Integer;
        ea: Integer;
        hl: Integer;
        xy: Integer;
    begin
        if IsIY then xy := rIY else xy := rIX;
        op := Rom[RomBase + rPC + 1];
        rPC += 1;
        case op of
            9:
                begin
                    Cyc += 15;
                    w := rB * 256 + rC;
                    hl := xy;
                    t := hl + w;
                    rF := AndT[rF * 256 + 197];
                    if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    xy := t;
                    rF += XYT[t div 256 + 1];
                end;
            25:
                begin
                    Cyc += 15;
                    w := rD * 256 + rE;
                    hl := xy;
                    t := hl + w;
                    rF := AndT[rF * 256 + 197];
                    if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    xy := t;
                    rF += XYT[t div 256 + 1];
                end;
            33:
                begin
                    Cyc += 14;
                    xy := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                end;
            34:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> xy mod 256 then begin Mem[ea + 1] := xy mod 256; WrCnt += 1; end; end else WriteMem(ea, xy mod 256);
                    ea := (ea + 1) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> xy div 256 then begin Mem[ea + 1] := xy div 256; WrCnt += 1; end; end else WriteMem(ea, xy div 256);
                end;
            35:
                begin
                    Cyc += 10;
                    xy := (xy + 1) mod 65536;
                end;
            36:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    if v = 255 then v := 0 else v += 1;
                    rF := (rF mod 2) + SZHVinc[v + 1];
                    xy := v * 256 + xy mod 256;
                end;
            37:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    if v = 0 then v := 255 else v -= 1;
                    rF := (rF mod 2) + SZHVdec[v + 1];
                    xy := v * 256 + xy mod 256;
                end;
            38:
                begin
                    Cyc += 11;
                    v := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    xy := v * 256 + xy mod 256;
                end;
            41:
                begin
                    Cyc += 15;
                    w := xy;
                    hl := xy;
                    t := hl + w;
                    rF := AndT[rF * 256 + 197];
                    if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    xy := t;
                    rF += XYT[t div 256 + 1];
                end;
            42:
                begin
                    Cyc += 20;
                    ea := Rom[RomBase + rPC + 1] + 256 * Rom[RomBase + rPC + 2];
                    rPC += 2;
                    if ea >= 32768 then n := Mem[ea + 1] else if ea < 16384 then n := Rom[RomBase + ea + 1] else n := ReadMem(ea);
                    ea := (ea + 1) mod 65536;
                    if ea >= 32768 then t := Mem[ea + 1] else if ea < 16384 then t := Rom[RomBase + ea + 1] else t := ReadMem(ea);
                    xy := t * 256 + n;
                end;
            43:
                begin
                    Cyc += 10;
                    xy := (xy + 65535) mod 65536;
                end;
            44:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    if v = 255 then v := 0 else v += 1;
                    rF := (rF mod 2) + SZHVinc[v + 1];
                    xy := (xy div 256) * 256 + v;
                end;
            45:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    if v = 0 then v := 255 else v -= 1;
                    rF := (rF mod 2) + SZHVdec[v + 1];
                    xy := (xy div 256) * 256 + v;
                end;
            46:
                begin
                    Cyc += 11;
                    v := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    xy := (xy div 256) * 256 + v;
                end;
            52:
                begin
                    Cyc += 23;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    if v = 255 then v := 0 else v += 1;
                    rF := (rF mod 2) + SZHVinc[v + 1];
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                end;
            53:
                begin
                    Cyc += 23;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    if v = 0 then v := 255 else v -= 1;
                    rF := (rF mod 2) + SZHVdec[v + 1];
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> v then begin Mem[ea + 1] := v; WrCnt += 1; end; end else WriteMem(ea, v);
                end;
            54:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    n := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> n then begin Mem[ea + 1] := n; WrCnt += 1; end; end else WriteMem(ea, n);
                end;
            57:
                begin
                    Cyc += 15;
                    w := rSP;
                    hl := xy;
                    t := hl + w;
                    rF := AndT[rF * 256 + 197];
                    if (hl mod 4096) + (w mod 4096) > 4095 then rF += 16;
                    if t > 65535 then begin t -= 65536; rF += 1; end;
                    xy := t;
                    rF += XYT[t div 256 + 1];
                end;
            68:
                begin
                    Cyc += 8;
                    rB := xy div 256;
                end;
            69:
                begin
                    Cyc += 8;
                    rB := xy mod 256;
                end;
            70:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rB := Mem[ea + 1] else if ea < 16384 then rB := Rom[RomBase + ea + 1] else rB := ReadMem(ea);
                end;
            76:
                begin
                    Cyc += 8;
                    rC := xy div 256;
                end;
            77:
                begin
                    Cyc += 8;
                    rC := xy mod 256;
                end;
            78:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rC := Mem[ea + 1] else if ea < 16384 then rC := Rom[RomBase + ea + 1] else rC := ReadMem(ea);
                end;
            84:
                begin
                    Cyc += 8;
                    rD := xy div 256;
                end;
            85:
                begin
                    Cyc += 8;
                    rD := xy mod 256;
                end;
            86:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rD := Mem[ea + 1] else if ea < 16384 then rD := Rom[RomBase + ea + 1] else rD := ReadMem(ea);
                end;
            92:
                begin
                    Cyc += 8;
                    rE := xy div 256;
                end;
            93:
                begin
                    Cyc += 8;
                    rE := xy mod 256;
                end;
            94:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rE := Mem[ea + 1] else if ea < 16384 then rE := Rom[RomBase + ea + 1] else rE := ReadMem(ea);
                end;
            96:
                begin
                    Cyc += 8;
                    v := rB;
                    xy := v * 256 + xy mod 256;
                end;
            97:
                begin
                    Cyc += 8;
                    v := rC;
                    xy := v * 256 + xy mod 256;
                end;
            98:
                begin
                    Cyc += 8;
                    v := rD;
                    xy := v * 256 + xy mod 256;
                end;
            99:
                begin
                    Cyc += 8;
                    v := rE;
                    xy := v * 256 + xy mod 256;
                end;
            100:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    xy := v * 256 + xy mod 256;
                end;
            101:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    xy := v * 256 + xy mod 256;
                end;
            102:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rH := Mem[ea + 1] else if ea < 16384 then rH := Rom[RomBase + ea + 1] else rH := ReadMem(ea);
                end;
            103:
                begin
                    Cyc += 8;
                    v := rA;
                    xy := v * 256 + xy mod 256;
                end;
            104:
                begin
                    Cyc += 8;
                    v := rB;
                    xy := (xy div 256) * 256 + v;
                end;
            105:
                begin
                    Cyc += 8;
                    v := rC;
                    xy := (xy div 256) * 256 + v;
                end;
            106:
                begin
                    Cyc += 8;
                    v := rD;
                    xy := (xy div 256) * 256 + v;
                end;
            107:
                begin
                    Cyc += 8;
                    v := rE;
                    xy := (xy div 256) * 256 + v;
                end;
            108:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    xy := (xy div 256) * 256 + v;
                end;
            109:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    xy := (xy div 256) * 256 + v;
                end;
            110:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rL := Mem[ea + 1] else if ea < 16384 then rL := Rom[RomBase + ea + 1] else rL := ReadMem(ea);
                end;
            111:
                begin
                    Cyc += 8;
                    v := rA;
                    xy := (xy div 256) * 256 + v;
                end;
            112:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rB then begin Mem[ea + 1] := rB; WrCnt += 1; end; end else WriteMem(ea, rB);
                end;
            113:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rC then begin Mem[ea + 1] := rC; WrCnt += 1; end; end else WriteMem(ea, rC);
                end;
            114:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rD then begin Mem[ea + 1] := rD; WrCnt += 1; end; end else WriteMem(ea, rD);
                end;
            115:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rE then begin Mem[ea + 1] := rE; WrCnt += 1; end; end else WriteMem(ea, rE);
                end;
            116:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rH then begin Mem[ea + 1] := rH; WrCnt += 1; end; end else WriteMem(ea, rH);
                end;
            117:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rL then begin Mem[ea + 1] := rL; WrCnt += 1; end; end else WriteMem(ea, rL);
                end;
            119:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> rA then begin Mem[ea + 1] := rA; WrCnt += 1; end; end else WriteMem(ea, rA);
                end;
            124:
                begin
                    Cyc += 8;
                    rA := xy div 256;
                end;
            125:
                begin
                    Cyc += 8;
                    rA := xy mod 256;
                end;
            126:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then rA := Mem[ea + 1] else if ea < 16384 then rA := Rom[RomBase + ea + 1] else rA := ReadMem(ea);
                end;
            132:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    t := rA + v;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            133:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    t := rA + v;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            134:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA + v;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            140:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    c := rF mod 2;
                    t := rA + v + c;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) + c > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            141:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    c := rF mod 2;
                    t := rA + v + c;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) + c > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            142:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    c := rF mod 2;
                    t := rA + v + c;
                    if t > 255 then begin t -= 256; rF := SZ[t + 1] + 1; end else rF := SZ[t + 1];
                    if (rA mod 16) + (v mod 16) + c > 15 then rF += 16;
                    if ((rA < 128) = (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            148:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            149:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            150:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            156:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    c := rF mod 2;
                    t := rA - v - c;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) - (v mod 16) - c < 0 then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            157:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    c := rF mod 2;
                    t := rA - v - c;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) - (v mod 16) - c < 0 then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            158:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    c := rF mod 2;
                    t := rA - v - c;
                    if t < 0 then begin t += 256; rF := SZ[t + 1] + 3; end else rF := SZ[t + 1] + 2;
                    if (rA mod 16) - (v mod 16) - c < 0 then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                    rA := t;
                end;
            164:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    rA := AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1] + 16;
                end;
            165:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    rA := AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1] + 16;
                end;
            166:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    rA := AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1] + 16;
                end;
            172:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    rA := rA + v - 2 * AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            173:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    rA := rA + v - 2 * AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            174:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    rA := rA + v - 2 * AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            180:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    rA := rA + v - AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            181:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    rA := rA + v - AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            182:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    rA := rA + v - AndT[rA * 256 + v + 1];
                    rF := SZP[rA + 1];
                end;
            188:
                begin
                    Cyc += 8;
                    v := xy div 256;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[v + 1]; end else rF := SZ0[t + 1] + 2 + XYT[v + 1];
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                end;
            189:
                begin
                    Cyc += 8;
                    v := xy mod 256;
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[v + 1]; end else rF := SZ0[t + 1] + 2 + XYT[v + 1];
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                end;
            190:
                begin
                    Cyc += 19;
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    if ea >= 32768 then v := Mem[ea + 1] else if ea < 16384 then v := Rom[RomBase + ea + 1] else v := ReadMem(ea);
                    t := rA - v;
                    if t < 0 then begin t += 256; rF := SZ0[t + 1] + 3 + XYT[v + 1]; end else rF := SZ0[t + 1] + 2 + XYT[v + 1];
                    if (rA mod 16) < (v mod 16) then rF += 16;
                    if ((rA < 128) <> (v < 128)) and ((rA < 128) <> (t < 128)) then rF += 4;
                end;
            203:
                begin
                    d := Rom[RomBase + rPC + 1];
                    rPC += 1;
                    if d >= 128 then d -= 256;
                    ea := (xy + d + 65536) mod 65536;
                    ExecXYCB(ea);
                end;
            225:
                begin
                    Cyc += 14;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    if rSP >= 32768 then t := Mem[rSP + 1] else if rSP < 16384 then t := Rom[RomBase + rSP + 1] else t := ReadMem(rSP);
                    rSP := (rSP + 1) mod 65536;
                    xy := t * 256 + n;
                end;
            227:
                begin
                    Cyc += 23;
                    if rSP >= 32768 then n := Mem[rSP + 1] else if rSP < 16384 then n := Rom[RomBase + rSP + 1] else n := ReadMem(rSP);
                    ea := (rSP + 1) mod 65536;
                    if ea >= 32768 then t := Mem[ea + 1] else if ea < 16384 then t := Rom[RomBase + ea + 1] else t := ReadMem(ea);
                    if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> xy mod 256 then begin Mem[rSP + 1] := xy mod 256; WrCnt += 1; end; end else WriteMem(rSP, xy mod 256);
                    if (ea >= 32768) and (ea < 40960) then begin if Mem[ea + 1] <> xy div 256 then begin Mem[ea + 1] := xy div 256; WrCnt += 1; end; end else WriteMem(ea, xy div 256);
                    xy := t * 256 + n;
                end;
            229:
                begin
                    Cyc += 15;
                    rSP := (rSP + 65535) mod 65536;
                    if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> xy div 256 then begin Mem[rSP + 1] := xy div 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, xy div 256);
                    rSP := (rSP + 65535) mod 65536;
                    if (rSP >= 32768) and (rSP < 40960) then begin if Mem[rSP + 1] <> xy mod 256 then begin Mem[rSP + 1] := xy mod 256; if rSP >= IdleSP then WrCnt += 1; end; end else WriteMem(rSP, xy mod 256);
                end;
            233:
                begin
                    Cyc += 8;
                    rPC := xy;
                end;
            249:
                begin
                    Cyc += 10;
                    rSP := xy;
                end;
            else begin
                Cyc += 4;
                rPC -= 1;
                exit;
            end;
        end;
        if IsIY then rIY := xy else rIX := xy;
    end;

    /// <summary>The CB rotate and shift operations: RLC RRC RL RR SLA SRA SLL SRL.</summary>
    local procedure RotOp(Kind: Integer; V: Integer): Integer
    var
        Res: Integer;
        Cy: Integer;
    begin
        case Kind of
            0: begin Cy := V div 128; Res := (V * 2) mod 256 + Cy; end;
            1: begin Cy := V mod 2; Res := V div 2 + Cy * 128; end;
            2: begin Cy := V div 128; Res := (V * 2) mod 256 + rF mod 2; end;
            3: begin Cy := V mod 2; Res := V div 2 + (rF mod 2) * 128; end;
            4: begin Cy := V div 128; Res := (V * 2) mod 256; end;
            5: begin Cy := V mod 2; Res := V div 2 + (V div 128) * 128; end;
            6: begin Cy := V div 128; Res := (V * 2) mod 256 + 1; end;
            7: begin Cy := V mod 2; Res := V div 2; end;
        end;
        rF := SZP[Res + 1] + Cy;
        exit(Res);
    end;

    /// <summary>
    /// Fetches an opcode when the program counter is outside the ROM (never in Galaga): the instruction bytes are
    /// copied to a scratch area after the ROMs, and RomBase points there until the next opcode fetch.
    /// </summary>
    local procedure FetchSlow(): Integer
    var
        i: Integer;
    begin
        if RamCode then begin
            RamCode := false;
            RomBase := (CpuNo - 1) * 16384;
            if rPC < 16384 then
                exit(Rom[RomBase + rPC + 1]);
        end;
        for i := 0 to 3 do
            Rom[49153 + i] := ReadMem((rPC + i) mod 65536);
        RomBase := 49152 - rPC;
        RamCode := true;
        exit(Rom[49153]);
    end;

    /// <summary>
    /// A short backward jump reached the same target twice in a row. When nothing was written and the registers
    /// are the same as at the previous visit, the loop can only be waiting for an interrupt or for another CPU
    /// (which runs after this one in the time slice): skip to the end of the slice.
    /// </summary>
    local procedure IdleCheck()
    begin
        if (WrCnt = IdleW) and (rA = IdleA) and (rF = IdleF) and (rB = IdleB) and (rC = IdleC) and (rD = IdleD) and
           (rE = IdleE) and (rH = IdleH) and (rL = IdleL) and (rSP = IdleSP) and (rIX = IdleIX) and (rIY = IdleIY) and
           (AF2 = IdleAF2) and (BC2 = IdleBC2) and (DE2 = IdleDE2) and (HL2 = IdleHL2)
        then begin
            IdleCycles[CpuNo] += RunTarget - Cyc;
            Cyc := RunTarget;
            exit;
        end;
        IdleW := WrCnt;
        IdleA := rA;
        IdleF := rF;
        IdleB := rB;
        IdleC := rC;
        IdleD := rD;
        IdleE := rE;
        IdleH := rH;
        IdleL := rL;
        IdleSP := rSP;
        IdleIX := rIX;
        IdleIY := rIY;
        IdleAF2 := AF2;
        IdleBC2 := BC2;
        IdleDE2 := DE2;
        IdleHL2 := HL2;
    end;
    // </generated z80>
}
