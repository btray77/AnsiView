/// Code page 437 to Unicode, including the graphic glyphs DOS shows for control codes.
public enum CP437 {
    public static let unicode: [Unicode.Scalar] = Array((
        "\u{0020}☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
        + " !\"#$%&'()*+,-./0123456789:;<=>?"
        + "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
        + "`abcdefghijklmnopqrstuvwxyz{|}~⌂"
        + "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ"
        + "áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
        + "└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
        + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    ).unicodeScalars)
}
