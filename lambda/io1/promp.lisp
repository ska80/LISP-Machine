;;; -*- Mode: LISP; Package: USER; Base:8 -*-

;;; Routines to hack the prom programmer
;;; Type "Select F1 Start" on the "System 19" to put it in remote mode
;;; This program operates at 300 baud at MIT but at 1200 baud at Symbolics.
;;; Other sites should edit in whatever speed they prefer.

;;; Modified 8/8/79 by Moon to use the IOB serial interface
;;; Requires version 9 or later of LMIO;SERIAL.

;;; Useful functions to call are:
;;; PROGRAMMER-RESET - resets everything, reads prom geometry from programmer.
;;;                             Call this before trying to do anything else.
;;; PROGRAMMER-UNWEDGE
;;; PROGRAMMER-PROGRAM-PROM - the argument is a prom-name.
;;;   A prom-name is a symbol whose value is an array containing the data.
;;; PROGRAMMER-READ-PROM - argument is a prom-name (there are some optionals too.)
;;;                             This reads the prom that is in the programmer into
;;;                             an array in the lisp machine.
;;; PROGRAMMER-READ-PROM-FILE - arguments are file name and prom-name.
;;; PROGRAMMER-WRITE-PROM-FILE - arguments are file name and prom-name.
;;; PROGRAMMER-MAKE-BOOTSTRAP - makes a set of Lisp machine bootstrap proms.
;;;                             Giving it an argument allows you to do one over.
;;;     The files this runs off of are generated by assembling the prom program
;;;     with the micro-assembler (probably in Maclisp) then loading the file
;;;     AI:MOON;PUNCH into that Lisp and typing (punch)


(DEFVAR PROGRAMMER-STREAM NIL "The stream that reads//writes the prom programmer.")
(DEFVAR PROGRAMMER-TRACE NIL "T to print all characters read from the prom programmer.")

(DEFUN GET-PROGRAMMER-CHAR (&OPTIONAL (IMAGE-P NIL))
  "Read a character or byte from the prom programmer.
IMAGE-P says do not translate from ASCII to the Lisp machine character set."
  (DO ((CHAR))
      (CHAR CHAR)
    (SETQ CHAR (FUNCALL PROGRAMMER-STREAM ':TYI))
    (COND ((NOT IMAGE-P)
           (SETQ CHAR (LOGAND CHAR 177))
           (COND ((OR (= CHAR 12) (= CHAR 0))
                  (SETQ CHAR NIL)))))
    (AND CHAR PROGRAMMER-TRACE (TYO CHAR))))

;;; Low level routines to get data to/from the programmer

(DEFUN PROGRAMMER-COMMAND (COMMAND &OPTIONAL RESPONSE-P (IMAGE-P NIL) &AUX ACK RESP)
  "Send COMMAND (a string) to the prom programmer.
RESPONSE-P should be NIL if no response expected but success//failure checked,
 NONE if even success//failure should not be checked,
 or the length of the expected response.
First value is the response from the programmer (if one is requested).
Second value is NIL if the command succeded,
 UNKNOWN if the command was unknown, and T if the command failed."
  (DECLARE (RETURN-LIST RESPONSE FAILURE-P))
  (PROG ()
    (FUNCALL PROGRAMMER-STREAM ':CLEAR-INPUT)
    (FUNCALL PROGRAMMER-STREAM ':STRING-OUT COMMAND)
    (FUNCALL PROGRAMMER-STREAM ':TYO 15)        ;Start the command
    (COND ((NOT RESPONSE-P))
          ((EQ RESPONSE-P 'NONE)
           (RETURN NIL NIL))
          (T (SETQ RESP (MAKE-ARRAY RESPONSE-P
                                    ':TYPE 'ART-STRING))
             (DOTIMES (I RESPONSE-P)
               (ASET (GET-PROGRAMMER-CHAR IMAGE-P) RESP I))))
    (SETQ ACK (GET-PROGRAMMER-CHAR))
    (OR (= (GET-PROGRAMMER-CHAR) 15)    ;Programmer terminates ack with a 15
        (FERROR NIL "Programmer did not send <CR> after ack"))
    (SELECTQ ACK
      (#/> (RETURN RESP NIL))           ;Success
      (#/F (RETURN RESP T))             ;Failure
      (#/? (RETURN RESP 'UNKNOWN))      ;Unknown command
      (OTHERWISE (FERROR NIL "Ack from programmer was ~S, which is Unknown" ACK)))))

;;; Resets the programmer, and reads out various pieces of state information
(DECLARE (SPECIAL PROGRAMMER-DEVICE-WORD-LIMIT PROGRAMMER-BYTE-SIZE
                  PROGRAMMER-VOL-VOH-STATUS))

(DEFUN PROGRAMMER-RESET ()
  "Reset the prom programmer control system and read the prom geometry.
Call this to prepare for any other operation on a prom."
  (IF (NULL PROGRAMMER-STREAM)
      (SETQ PROGRAMMER-STREAM (SI:MAKE-SERIAL-STREAM
                                ':PARITY NIL
                                ':NUMBER-OF-DATA-BITS 8
                                ':BAUD #+MIT 300. #+SYM 1200.)))
  (FUNCALL PROGRAMMER-STREAM ':CLEAR-INPUT)
  (FUNCALL PROGRAMMER-STREAM ':TYO 33)          ;This resets the programmer
  (DO ((CHAR (GET-PROGRAMMER-CHAR) (GET-PROGRAMMER-CHAR)))
      ((= CHAR #/>)))
  (DO ((CHAR (GET-PROGRAMMER-CHAR) (GET-PROGRAMMER-CHAR)))
      ((= CHAR 15)))                            ;Wait for programmer to ack
  (LET ((RESP (PROGRAMMER-COMMAND "R" 7)))
    (SETQ PROGRAMMER-DEVICE-WORD-LIMIT (HEX-STRING-TO-FIXNUM (NSUBSTRING RESP 0 3))
          PROGRAMMER-BYTE-SIZE (HEX-STRING-TO-FIXNUM (NSUBSTRING RESP 4 5))
          PROGRAMMER-VOL-VOH-STATUS (HEX-STRING-TO-FIXNUM (NSUBSTRING RESP 6 7))))
  T)

(DEFUN HEX-STRING-TO-FIXNUM (STRING &AUX (NUM 0) CHAR)
  (DOTIMES (I (STRING-LENGTH STRING))
    (SETQ CHAR (AREF STRING I))
    (SETQ NUM (+ (* NUM 20)
                 (COND ((AND ( CHAR #/0) ( CHAR #/9))
                        (- CHAR #/0))
                       ((AND ( CHAR #/A) ( CHAR #/F))
                        (- CHAR (- #/A 10.)))
                       (T (RETURN NIL))))))
  NUM)

;;; Reads the contents of the ram using Intel Intellec 8/MDS format, code 83
(DECLARE (SPECIAL PROGRAMMER-CHECKSUM))

(DEFUN PROGRAMMER-READ-RAM (&OPTIONAL (ARRAY (MAKE-ARRAY
                                               (1+ PROGRAMMER-DEVICE-WORD-LIMIT)
                                               ':TYPE 'ART-8B)))
  (PROGRAMMER-RESET)
  (MULTIPLE-VALUE-BIND (IGNORE FAILURE)
      (PROGRAMMER-COMMAND "83A" NIL)
    (AND FAILURE
         (FERROR NIL "Cannot set transfer format"))
    (PROGRAMMER-COMMAND "O" 'NONE)
    (DO ((BYTE-COUNT) (PROGRAMMER-CHECKSUM 0 0) (ADR 0) (CS) (RECORD-TYPE)
         (ARRAY-LEN (ARRAY-LENGTH ARRAY)))
        (())
      ;Start character is a colon
      (DO CHAR (GET-PROGRAMMER-CHAR) (GET-PROGRAMMER-CHAR) (= CHAR #/:))
      (SETQ BYTE-COUNT (HEX-READ-BYTE))
      (SETQ ADR (+ (LSH (HEX-READ-BYTE) 8.) (HEX-READ-BYTE)))
      (SETQ RECORD-TYPE (HEX-READ-BYTE))
      (SELECTQ RECORD-TYPE
        (00                                     ;Data record
         (COND (( ADR ARRAY-LEN)
                ;; With the new software, it seems that the programmer can overrun the array
                (FORMAT T "~&Programmer sending too much data (bc ~O, adr ~O), resetting.~@
                           This is probably not an error."
                          BYTE-COUNT ADR)
                (PROGRAMMER-RESET)
                (RETURN NIL)))
         (DOTIMES (I BYTE-COUNT)
           (LET ((BYTE (HEX-READ-BYTE)))
             (AND  (< (+ ADR I) ARRAY-LEN)
                   (ASET BYTE ARRAY (+ ADR I)))))
         (SETQ CS (LOGAND (- PROGRAMMER-CHECKSUM) 377))
         (COND (( (SETQ RECORD-TYPE (HEX-READ-BYTE)) CS)
                (FORMAT T "Checksum error, trying again~%")
                (PROGRAMMER-RESET)
                (RETURN (PROGRAMMER-READ-RAM ARRAY)))))
        (01                                     ;EOF record
         (DO CHAR (GET-PROGRAMMER-CHAR) (GET-PROGRAMMER-CHAR) (= CHAR #/>))
         (GET-PROGRAMMER-CHAR)
         (RETURN NIL)))))                       ;Read trailing <CR>
  ARRAY)


;;; Sets the contents of the ram using Intel Intellec 8/MDS format, code 83
(DEFUN PROGRAMMER-WRITE-RAM (ARRAY &OPTIONAL (RECORD-MAX-LENGTH 20))
  (PROGRAMMER-RESET)                            ;Reset programmer, read word limit info
  (PROGRAMMER-READ-ERROR-STATUS)                ;Reset the error code to zero
  (MULTIPLE-VALUE-BIND (IGNORE FAILURE)
      (PROGRAMMER-COMMAND "83A" NIL)
    (AND FAILURE
         (FERROR NIL "Cannot set transfer format"))
    (PROGRAMMER-COMMAND "I" 'NONE)
    (FUNCALL PROGRAMMER-STREAM ':TYO 15) (FUNCALL PROGRAMMER-STREAM ':TYO 12)
    (DOTIMES (I 20.)                            ;Seems to need some pad characters
      (FUNCALL PROGRAMMER-STREAM ':TYO 0))
    (DO ((LEFT (1+ PROGRAMMER-DEVICE-WORD-LIMIT) (- LEFT RECORD-LEN))
         (ARRAY-LENGTH (ARRAY-LENGTH ARRAY))
         (IDX 0 (+ IDX RECORD-LEN))
         (CHECKSUM)
         (RECORD-LEN))
        (( LEFT 0))
      (SETQ RECORD-LEN (MIN LEFT RECORD-MAX-LENGTH))
      (FUNCALL PROGRAMMER-STREAM ':TYO #/:)
      (NUMBER-PRINT RECORD-LEN 8. 16. PROGRAMMER-STREAM)        ;Byte count
      (NUMBER-PRINT IDX 16. 16. PROGRAMMER-STREAM)      ;Address
      (SETQ CHECKSUM (+ RECORD-LEN (LOGAND IDX 377) (LDB 1010 IDX)))
      (FUNCALL PROGRAMMER-STREAM ':STRING-OUT "00")     ;Record type 0: data
      (DOTIMES (I RECORD-LEN)
        (NUMBER-PRINT (COND ((< (+ IDX I) ARRAY-LENGTH)
                             (SETQ CHECKSUM (+ CHECKSUM (AREF ARRAY (+ IDX I))))
                             (AREF ARRAY (+ IDX I)))
                            (T 0))
                      8. 16. PROGRAMMER-STREAM))
      (NUMBER-PRINT (LOGAND (- CHECKSUM) 377) 8. 16. PROGRAMMER-STREAM)
      (FUNCALL PROGRAMMER-STREAM ':TYO 15) (FUNCALL PROGRAMMER-STREAM ':TYO 12))
    (FUNCALL PROGRAMMER-STREAM ':STRING-OUT ":00000001")        ;EOF record
    (FUNCALL PROGRAMMER-STREAM ':TYO 15) (FUNCALL PROGRAMMER-STREAM ':TYO 12)
    (PROGRAMMER-RESET)
    (PROGRAMMER-READ-ERROR-STATUS)))

(DEFUN HEX-READ-BYTE (&AUX BYTE (STRING (MAKE-ARRAY 2 ':TYPE 'ART-STRING)))
  (ASET (GET-PROGRAMMER-CHAR) STRING 0)
  (ASET (GET-PROGRAMMER-CHAR) STRING 1)
  (SETQ PROGRAMMER-CHECKSUM
        (+ PROGRAMMER-CHECKSUM (SETQ BYTE (HEX-STRING-TO-FIXNUM STRING))))
  (RETURN-ARRAY STRING)
  BYTE)

(DEFUN NUMBER-PRINT (NUMBER SIG-BITS BASE &OPTIONAL (STREAM STANDARD-OUTPUT))
  (LET ((DIG)
        (DIGITS)
        (BITS (1- (HAULONG BASE))))
    (SETQ DIGITS (TRUNCATE (+ SIG-BITS BITS -1) BITS))
    (DOTIMES (I DIGITS)
      (SETQ DIG (LDB (+ BITS (LSH (* BITS (- DIGITS I 1)) 6.)) NUMBER))
      (COND ((< DIG 10.) (TYO (+ DIG #/0) STREAM))
            (T (TYO (+ DIG #/A -10.) STREAM))))))

(DEFUN NUMBER-LENGTH (NUMBER BASE)
  (TRUNCATE (+ (HAULONG NUMBER) (1- (HAULONG BASE)) -1)
            (1- (HAULONG BASE))))

(DEFUN PROGRAMMER-READ-ERROR-STATUS ()
  (PROGRAMMER-COMMAND "F" 8.))

(DEFUN PROGRAMMER-UNWEDGE ()
  "Attempt to clean up an error condition in the prom programmer."
  (PROGRAMMER-RESET)
  (PROGRAMMER-COMMAND "I" 'NONE)
  (PROGRAMMER-RESET)
  (PROGRAMMER-READ-ERROR-STATUS))

(DEFUN PROGRAMMER-PROGRAM-PROM (PROM-PROGRAM)
  "Write PROM-PROGRAM into the plugged in prom.
PROM-PROGRAM should be a symbol whose value is an array holding the data."
  (LET ((PROM-ARRAY (IF (SYMBOLP PROM-PROGRAM)
                        (SYMEVAL PROM-PROGRAM)
                      PROM-PROGRAM)))
    (FORMAT T "~&Writing ~A into programmer~%" PROM-PROGRAM)
    (DO ((ERROR-CODE (PROGRAMMER-WRITE-RAM PROM-ARRAY)
                     (PROGRAMMER-WRITE-RAM PROM-ARRAY)))
        ((STRING-EQUAL ERROR-CODE "00000000"))
      (FORMAT T "Error writing PROM, error code ~a. Retrying.~%" ERROR-CODE))
    (FORMAT T "Verifying ram~%")
    (LET ((ARRAY (PROGRAMMER-READ-RAM))
          (PROM-LENGTH (ARRAY-LENGTH PROM-ARRAY)))
      (COND ((DOTIMES (I (ARRAY-LENGTH ARRAY))
               (COND ((< I PROM-LENGTH)
                      (COND (( (AREF ARRAY I) (AREF PROM-ARRAY I))
                             (FORMAT T "Data compare error, ")
                             (RETURN T))))
                     (( (AREF ARRAY I) 0)
                      (FORMAT T "Unwritten data not zero, ")
                      (RETURN T))))
             (FORMAT T "Ram readback failed, try again?~%")
             NIL)
            (T (PROGRAMMER-WRITE-PROM)
               T)))))

(DEFUN PROGRAMMER-WRITE-PROM ()
  (PROG (VAL FAIL)
   (FORMAT T "~&Insert fresh PROM, type Y when ready: ")
   (OR (Y-OR-N-P) (RETURN NIL))
   (MULTIPLE-VALUE (VAL FAIL)
     (PROGRAMMER-COMMAND "B"))
   (COND (FAIL
          (FORMAT T "~&PROM is not blank, proceed anyway? ")
          (OR (Y-OR-N-P) (RETURN NIL))))
   (MULTIPLE-VALUE (VAL FAIL)
     (PROGRAMMER-COMMAND "T"))
   (COND (FAIL
          (FORMAT T "~&PROM has bad bit, proceed anyway? ")
          (OR (Y-OR-N-P) (RETURN NIL))))
   (FORMAT T "~&Programming PROM")
   (MULTIPLE-VALUE (VAL FAIL)
     (PROGRAMMER-COMMAND "P"))
   (COND (FAIL
          (FORMAT T "~&Programming failed.")
          (RETURN NIL)))
   (FORMAT T "~&Verifying device.")
   (MULTIPLE-VALUE (VAL FAIL)
     (PROGRAMMER-COMMAND "V"))
   (AND FAIL (FORMAT T "~&PROM fails to verify."))))

;;; Routines to read and write "Standard" format proms
(DEFUN PROGRAMMER-READ-PROM-FILE (FILENAME PROM-NAME)
  "Read a prom program from FILENAME and call it PROM-NAME.
PROM-NAME should be a symbol.  After this is done,
you can use that symbol in PROGRAMMER-PROGRAM-PROM."
  (LET ((FILE (OPEN FILENAME '(IN)))
        (PACKAGE (PKG-FIND-PACKAGE "USER"))
        (IBASE 8.)
        (TOKEN))
    (SETQ TOKEN (READ FILE))
    (OR (EQ TOKEN 'USER:PROM)
        (FERROR NIL "Starting token is, ~S, not ~S" TOKEN 'USER:PROM))
    (DO () (())
      (SETQ TOKEN (READ FILE))
      (AND (NUMBERP TOKEN) (RETURN NIL))
      (PUTPROP PROM-NAME (READ FILE) TOKEN))
    (DO ((TOKEN TOKEN (READ FILE))
         (ARRAY (MAKE-ARRAY 1000))
         (LEN 1000)
         (MAX -1))
        ((EQ TOKEN 'USER:END)
         (SET PROM-NAME (ADJUST-ARRAY-SIZE ARRAY (1+ MAX))))
      (AND (> TOKEN MAX) (SETQ MAX TOKEN))
      (COND (( TOKEN LEN)
             (SETQ LEN (+ LEN 1000))
             (ADJUST-ARRAY-SIZE ARRAY LEN)))
      (ASET (READ FILE) ARRAY TOKEN))
    (CLOSE FILE)))

(DEFUN PROGRAMMER-WRITE-PROM-FILE (PROM-NAME FILENAME)
  "Write the prom program PROM-NAME into FILENAME."
  (LET ((FILE (OPEN FILENAME '(OUT)))
        (BASE 8.)
        (ARRAY (SYMEVAL PROM-NAME)))
    (PRINC "PROM " FILE)
    (DOLIST (PROP 'USER:(LOCATION SUM-CHECK))
      (FORMAT FILE "~A ~A " PROP (GET PROM-NAME PROP)))
    (TERPRI FILE) (TERPRI FILE)
    (DOTIMES (I (ARRAY-LENGTH ARRAY))
      (FORMAT FILE "~O ~O ~%" I (AREF ARRAY I)))
    (FORMAT FILE "~%END ~%")
    (CLOSE FILE)))

(DEFUN PROGRAMMER-READ-PROM (PROM-NAME &OPTIONAL (LOCATION 'UNKNOWN) (RAM-P NIL))
  "Read the contents of the plugged-in prom into PROM-NAME.
PROM-NAME is a symbol which will be set to an array containing the data.
LOCATION will be put on as a property.
Someone who knows what RAM-P means, please alter this line."
  (OR RAM-P (PROGRAMMER-COMMAND "L"))
  (SET PROM-NAME (PROGRAMMER-READ-RAM))
  (PUTPROP PROM-NAME LOCATION 'USER:LOCATION)
  (PUTPROP PROM-NAME (PROGRAMMER-COMMAND "S" 4) 'USER:SUM-CHECK)
  PROM-NAME)

;;; LISP MACHINE Specific stuff

;;; Routine to load and programm the bootstrap Prom set
(DEFUN PROGRAMMER-MAKE-BOOTSTRAP (&OPTIONAL (FROM NIL)
                                            (DIR "LISPM1;")
                                            &AUX PROM-FILE-LIST)
  (SETQ PROM-FILE-LIST `((CADR-1B19 . ,(STRING-APPEND "AI:" DIR "PROM 1B19"))
                         (CADR-1B17 . ,(STRING-APPEND "AI:" DIR "PROM 1B17"))
                         (CADR-1C20 . ,(STRING-APPEND "AI:" DIR "PROM 1C20"))
                         (CADR-1D16 . ,(STRING-APPEND "AI:" DIR "PROM 1D16"))
                         (CADR-1E19 . ,(STRING-APPEND "AI:" DIR "PROM 1E19"))
                         (CADR-1E17 . ,(STRING-APPEND "AI:" DIR "PROM 1E17"))))
  (OR FROM
      (DOLIST (PROM PROM-FILE-LIST)
        (PROGRAMMER-READ-PROM-FILE (CDR PROM) (CAR PROM))))
  (DOLIST (PROM PROM-FILE-LIST)
    (AND FROM
         (EQ (CAR PROM) FROM)
         (SETQ FROM NIL))
    (OR FROM (DO () ((PROGRAMMER-PROGRAM-PROM (CAR PROM))))))
  'DONE)
