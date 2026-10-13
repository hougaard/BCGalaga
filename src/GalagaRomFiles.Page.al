/// <summary>
/// The imported Galaga ROM files. Import a romset here (galaga.zip has the color and sound PROMs that the clone
/// sets lack); imported files take precedence over the ones that ship with the app.
/// </summary>
page 66701 "Galaga ROM Files"
{
    PageType = List;
    Caption = 'Galaga ROM Files';
    ApplicationArea = All;
    UsageCategory = Lists;
    SourceTable = "Galaga ROM File";
    Editable = false;
    DeleteAllowed = true;

    layout
    {
        area(Content)
        {
            repeater(Files)
            {
                field("File Name"; Rec."File Name")
                {
                    ToolTip = 'The name of the ROM file. The chip location at the end of the name (for example 3p) tells what the file holds.';
                }
                field(Size; Rec.Size)
                {
                    ToolTip = 'The size of the file in bytes.';
                }
                field("Imported At"; Rec."Imported At")
                {
                    ToolTip = 'When the file was imported.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(Import)
            {
                Caption = 'Import ROMs';
                ToolTip = 'Import a Galaga romset (zip) or a single ROM file.';
                Image = Import;

                trigger OnAction()
                var
                    Loader: Codeunit "Galaga ROM Loader";
                    GalagaSession: Codeunit "Galaga Session";
                    InS: InStream;
                    FileName: Text;
                begin
                    if not UploadIntoStream(ImportTitleTxt, '', 'ROM sets (*.zip)|*.zip|All files (*.*)|*.*', FileName, InS) then
                        exit;
                    Message(ImportedTxt, Loader.ImportFile(FileName, InS));
                    // the game starts again with the new ROMs
                    GalagaSession.Reset();
                end;
            }
            action(CheckRoms)
            {
                Caption = 'Check ROMs';
                ToolTip = 'Show which file is used for each ROM chip, from this list or from the app.';
                Image = Info;

                trigger OnAction()
                var
                    Loader: Codeunit "Galaga ROM Loader";
                begin
                    Message(Loader.DescribeRoms());
                end;
            }
            action(Play)
            {
                Caption = 'Play Galaga';
                ToolTip = 'Open the game.';
                Image = Start;
                RunObject = page Galaga;
            }
        }
        area(Promoted)
        {
            actionref(Import_Promoted; Import)
            {
            }
            actionref(CheckRoms_Promoted; CheckRoms)
            {
            }
            actionref(Play_Promoted; Play)
            {
            }
        }
    }

    var
        ImportTitleTxt: Label 'Import Galaga ROMs';
        ImportedTxt: Label '%1 ROM files imported.', Comment = '%1 = number of files';
}
