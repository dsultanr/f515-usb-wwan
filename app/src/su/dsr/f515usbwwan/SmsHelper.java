package su.dsr.f515usbwwan;

import android.content.Context;

import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Чтение и декодирование SMS-сообщений с USB-модема (ветка PPP / AT-порт).
 * Поддерживает форматы PDU и Text mode, декодирует кириллицу (UCS-2 / UTF-16BE),
 * 7-битный GSM-алфавит и буквенные имена отправителей (банки, операторы).
 */
public class SmsHelper {

    public static class SmsMessage {
        public final int index;
        public final String sender;
        public final String timestamp;
        public final String text;
        public final boolean unread;

        public SmsMessage(int index, String sender, String timestamp, String text, boolean unread) {
            this.index = index;
            this.sender = cleanString(sender != null && !sender.isEmpty() ? sender : "Неизвестный");
            this.timestamp = timestamp != null && !timestamp.isEmpty() ? timestamp : "";
            this.text = cleanString(text != null ? text : "");
            this.unread = unread;
        }

        private static String cleanString(String s) {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '\r') continue;
                if (c == '\n' || c == '\t' || c >= 32) {
                    sb.append(c);
                }
            }
            return sb.toString().trim();
        }
    }

    private static final char[] GSM_7BIT_CHARS = {
            '@', '£', '$', '¥', 'è', 'é', 'ù', 'ì', 'ò', 'Ç', '\n', 'Ø', 'ø', '\r', 'Å', 'å',
            'Δ', '_', 'Φ', 'Γ', 'Λ', 'Ω', 'Π', 'Ψ', 'Σ', 'Θ', 'Ξ', '\u001b', 'Æ', 'æ', 'ß', 'É',
            ' ', '!', '"', '#', '¤', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
            '¡', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
            'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Ä', 'Ö', 'Ñ', 'Ü', '§',
            '¿', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
            'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'ä', 'ö', 'ñ', 'ü', 'à'
    };

    /**
     * Считывает список всех SMS из памяти модема.
     */
    public static List<SmsMessage> readAll(Context ctx, Keeper.Progress progress) {
        String output = Keeper.runSms(ctx, "list", progress);
        return parseResponse(output);
    }

    /**
     * Удаляет конкретное сообщение по индексу.
     */
    public static String delete(Context ctx, int index, Keeper.Progress progress) {
        return Keeper.runSms(ctx, "delete " + index, progress);
    }

    /**
     * Удаляет все SMS из памяти модема.
     */
    public static String deleteAll(Context ctx, Keeper.Progress progress) {
        return Keeper.runSms(ctx, "delete_all", progress);
    }

    /**
     * Разбор вывода AT-команд (PDU и Text mode).
     */
    public static List<SmsMessage> parseResponse(String output) {
        List<SmsMessage> result = new ArrayList<>();
        if (output == null || output.trim().isEmpty()) {
            return result;
        }

        String[] lines = output.split("\n");
        int i = 0;
        while (i < lines.length) {
            String line = lines[i].trim();
            if (line.startsWith("+CMGL:")) {
                String header = line.substring(6).trim();
                String[] parts = header.split(",");
                // Седьмое поле "text" ставит HiLink-ветка (sms-hilink.sh): тело —
                // обычный текст, а не PDU. Только тогда не угадываем кодировку.
                boolean plainText = parts.length >= 7
                        && "text".equals(parts[6].trim().replace("\"", ""));
                int lastIndex = -1;
                boolean lastUnread = false;
                if (parts.length >= 2) {
                    try {
                        lastIndex = Integer.parseInt(parts[0].trim());
                        int stat = Integer.parseInt(parts[1].trim().replace("\"", ""));
                        lastUnread = (stat == 0 || stat == 1);
                    } catch (Exception ignored) {
                        lastIndex = -1;
                    }
                }

                // HiLink печатает тело сразу после заголовка, даже пустое;
                // в AT-режиме пустые строки — разделители.
                i++;
                if (!plainText) {
                    while (i < lines.length && lines[i].trim().isEmpty()) {
                        i++;
                    }
                }

                if (i < lines.length) {
                    String pduLine = lines[i].trim();
                    boolean nextHeader = !plainText
                            && (pduLine.equals("OK") || pduLine.startsWith("+CMGL:"));
                    if (!nextHeader) {
                        SmsMessage msg = null;
                        if (!plainText && isHex(pduLine) && pduLine.length() >= 20) {
                            msg = decodePdu(lastIndex, pduLine, lastUnread);
                        }
                        if (msg == null) {
                            // Fallback для Text-mode
                            String sender = parts.length >= 3 ? parts[2].replace("\"", "").trim() : "Неизвестный";
                            String ts = parts.length >= 5 ? parts[4].replace("\"", "").trim() : "";
                            msg = new SmsMessage(lastIndex, sender, ts,
                                    plainText ? pduLine : decodeIfHexUcs2(pduLine), lastUnread);
                        }
                        if (msg != null && !msg.text.isEmpty() && !containsIndex(result, msg.index, msg.text)) {
                            result.add(msg);
                        }
                    }
                }
            }
            i++;
        }

        // Сортировка: самые свежие сообщения сверху (по дате/времени, затем по индексу)
        Collections.sort(result, new Comparator<SmsMessage>() {
            @Override
            public int compare(SmsMessage a, SmsMessage b) {
                String tsA = a.timestamp != null ? a.timestamp : "";
                String tsB = b.timestamp != null ? b.timestamp : "";
                int cmp = tsB.compareTo(tsA);
                if (cmp != 0) {
                    return cmp;
                }
                return Integer.compare(b.index, a.index);
            }
        });

        return result;
    }

    private static boolean containsIndex(List<SmsMessage> list, int index, String text) {
        for (SmsMessage m : list) {
            if (m.index == index && m.text.equals(text)) return true;
        }
        return false;
    }

    /**
     * Декодирует PDU строку формата 3GPP TS 23.040.
     */
    private static SmsMessage decodePdu(int index, String hex, boolean unread) {
        try {
            byte[] pdu = hexToBytes(hex);
            if (pdu == null || pdu.length < 10) return null;

            int offset = 0;

            // 1. Длина SCA (SMSC)
            int scaLen = pdu[offset++] & 0xFF;
            if (scaLen > 0) {
                offset += scaLen;
            }

            if (offset >= pdu.length) return null;

            // 2. Первый байт (First Octet)
            int firstOctet = pdu[offset++] & 0xFF;
            boolean hasUdh = (firstOctet & 0x40) != 0;

            // 3. Originating Address (длина в полубайтах/цифрах)
            int oaDigits = pdu[offset++] & 0xFF;
            int oaType = pdu[offset++] & 0xFF;
            int oaBytesLen = (oaDigits + 1) / 2;

            if (offset + oaBytesLen > pdu.length) return null;

            String sender;
            if ((oaType & 0xF0) == 0xD0) {
                // Буквенно-цифровое имя отправителя (GSM 7-bit packed)
                int numSeptets = (oaDigits * 4) / 7;
                sender = decodeGsm7bit(pdu, offset, numSeptets, 0);
            } else {
                // Номер телефона с переставленными полубайтами
                StringBuilder sb = new StringBuilder();
                if (oaType == 0x91) sb.append('+');
                for (int j = 0; j < oaBytesLen; j++) {
                    int b = pdu[offset + j] & 0xFF;
                    int d1 = b & 0x0F;
                    int d2 = (b >> 4) & 0x0F;
                    if (d1 <= 9) sb.append(d1);
                    if (d2 <= 9 && (j != oaBytesLen - 1 || (oaDigits % 2 == 0))) sb.append(d2);
                }
                sender = sb.toString();
            }
            offset += oaBytesLen;

            // 4. Protocol Identifier
            if (offset >= pdu.length) return null;
            offset++; // TP-PID

            // 5. Data Coding Scheme
            if (offset >= pdu.length) return null;
            int dcs = pdu[offset++] & 0xFF;
            boolean isUcs2 = (dcs & 0x0C) == 0x08 || dcs == 0x08;
            boolean is8bit = (dcs & 0x0C) == 0x04 || dcs == 0x04;

            // 6. SCTS Timestamp (7 байт)
            if (offset + 7 > pdu.length) return null;
            String ts = String.format("20%s-%s-%s %s:%s:%s",
                    swapNibbles(pdu[offset]),
                    swapNibbles(pdu[offset + 1]),
                    swapNibbles(pdu[offset + 2]),
                    swapNibbles(pdu[offset + 3]),
                    swapNibbles(pdu[offset + 4]),
                    swapNibbles(pdu[offset + 5]));
            offset += 7;

            // 7. User Data Length (UDL)
            if (offset >= pdu.length) return null;
            int udl = pdu[offset++] & 0xFF;

            int udBytes = pdu.length - offset;
            int udOffset = offset;
            int fillBits = 0;

            // Если есть заголовок UDH (например длинные склеенные SMS)
            if (hasUdh && udBytes > 0) {
                int udhl = pdu[udOffset] & 0xFF;
                int udhTotal = 1 + udhl;
                udOffset += udhTotal;
                udBytes -= udhTotal;
                if (!isUcs2 && !is8bit) {
                    // В GSM 7-bit заголовок UDH смещает биты
                    int udhBits = udhTotal * 8;
                    fillBits = (7 - (udhBits % 7)) % 7;
                }
            }

            String text;
            if (isUcs2) {
                // Кириллица (UTF-16BE)
                StringBuilder sb = new StringBuilder();
                for (int j = 0; j + 1 < udBytes; j += 2) {
                    int ch = ((pdu[udOffset + j] & 0xFF) << 8) | (pdu[udOffset + j + 1] & 0xFF);
                    sb.append((char) ch);
                }
                text = sb.toString();
            } else if (is8bit) {
                text = new String(pdu, udOffset, Math.max(0, udBytes), Charset.forName("ISO-8859-1"));
            } else {
                // GSM 7-bit
                int septets = udl;
                if (hasUdh) {
                    septets -= ((pdu[offset] & 0xFF) + 1) * 8 / 7;
                }
                text = decodeGsm7bit(pdu, udOffset, septets, fillBits);
            }

            return new SmsMessage(index, sender, ts, text, unread);
        } catch (Exception e) {
            return null;
        }
    }

    private static String swapNibbles(byte b) {
        int v = b & 0xFF;
        int d1 = v & 0x0F;
        int d2 = (v >> 4) & 0x0F;
        return "" + d1 + d2;
    }

    private static String decodeGsm7bit(byte[] data, int offset, int numSeptets, int startBit) {
        if (data == null || offset >= data.length || numSeptets <= 0) return "";
        StringBuilder sb = new StringBuilder();
        int bitPos = startBit;
        for (int i = 0; i < numSeptets; i++) {
            int byteIndex = offset + (bitPos / 8);
            int bitOffset = bitPos % 8;
            if (byteIndex >= data.length) break;

            int val = (data[byteIndex] & 0xFF) >> bitOffset;
            if (bitOffset > 1 && byteIndex + 1 < data.length) {
                val |= (data[byteIndex + 1] & 0xFF) << (8 - bitOffset);
            }
            int code = val & 0x7F;
            if (code < GSM_7BIT_CHARS.length) {
                sb.append(GSM_7BIT_CHARS[code]);
            } else {
                sb.append('?');
            }
            bitPos += 7;
        }
        return sb.toString();
    }

    private static String decodeIfHexUcs2(String s) {
        if (s == null) return "";
        s = s.trim();
        if (isHex(s) && s.length() >= 4 && s.length() % 4 == 0) {
            try {
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < s.length(); i += 4) {
                    int val = Integer.parseInt(s.substring(i, i + 4), 16);
                    sb.append((char) val);
                }
                return sb.toString();
            } catch (Exception ignored) {}
        }
        return s;
    }

    private static boolean isHex(String s) {
        if (s == null || s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            boolean hexChar = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hexChar) return false;
        }
        return true;
    }

    private static byte[] hexToBytes(String hex) {
        if (hex == null || hex.length() % 2 != 0) return null;
        byte[] b = new byte[hex.length() / 2];
        for (int i = 0; i < b.length; i++) {
            b[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return b;
    }
}
