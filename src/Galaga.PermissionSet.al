permissionset 66700 "Galaga"
{
    Assignable = true;
    Caption = 'Play Galaga';

    Permissions =
        tabledata "Galaga ROM File" = RIMD,
        table "Galaga ROM File" = X,
        codeunit "Galaga Machine" = X,
        codeunit "Galaga ROM Loader" = X,
        codeunit "Galaga Session" = X,
        page Galaga = X,
        page "Galaga ROM Files" = X;
}
