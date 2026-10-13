/// <summary>
/// The Galaga screen: shows the frames of the "Galaga Machine" (224x288, the monitor is rotated), plays its sound
/// and sends the keyboard back to Business Central.
/// </summary>
controladdin "Galaga Screen"
{
    Scripts = 'src/controladdin/galaga/screen.js';
    StartupScript = 'src/controladdin/galaga/galaga.js';
    StyleSheets = 'src/controladdin/galaga/galaga.css';
    RequestedHeight = 720;
    MinimumHeight = 300;
    RequestedWidth = 560;
    MinimumWidth = 224;
    VerticalStretch = true;
    VerticalShrink = true;
    HorizontalStretch = true;
    HorizontalShrink = true;

    /// <summary>The add-in is loaded and ready.</summary>
    event ControlReady();

    /// <summary>
    /// Asks for the next frames. Input is a JSON array of the button events since the last request:
    /// [0,button] pressed, [1,button] released (see "Galaga Machine".SetButton for the buttons).
    /// ElapsedMs is the time since the previous request, FrameCount the number of frames wanted.
    /// </summary>
    event RequestFrames(Input: Text; ElapsedMs: Integer; FrameCount: Integer);

    /// <summary>The user wants to import ROM files.</summary>
    event ImportRomsRequested();

    /// <summary>The 97 colors (RRGGBB hex) and the 8 sound waveforms (256 hex digits, empty: built in ones).</summary>
    procedure Init(Palette: Text; Waves: Text);

    /// <summary>A batch of frames separated by ';' (see "Galaga Machine".GetFrameText). ServerMs: the time to make them.</summary>
    procedure DrawFrames(Frames: Text; ServerMs: Integer);

    /// <summary>Diagnostics (timings), shown with the ` key.</summary>
    procedure ShowInfo(Info: Text);

    /// <summary>A status text over the screen, with an import ROMs button.</summary>
    procedure ShowStatus(Message: Text; ShowImportButton: Boolean);

    /// <summary>A message shown for a few seconds.</summary>
    procedure ShowMessage(Message: Text);

    /// <summary>Starts the frame loop.</summary>
    procedure Start();
}
