;;
;; parsing and encoding code
;; 

(in-package :neo)


;; parseobj -- used for cons-free parsing of strings
(defconstant parseobj-size 20)

(defstruct parseobj
  (start (make-array parseobj-size))  ; first charpos
  (end   (make-array parseobj-size))  ; charpos after last
  (next  0) ; next index to use
  (max  parseobj-size)
  )

(defvar *parseobjs* nil) 

(defun allocate-parseobj ()
  (let (res)
    (mp::without-scheduling 
      (if* (setq res (pop *parseobjs*))
	 then (setf (parseobj-next res) 0)
	      res
	 else (make-parseobj)))))

(defun free-parseobj (po)
  (mp::without-scheduling
    (push po *parseobjs*)))

(defun add-to-parseobj (po start end)
  ;; add the given start,end pair to the parseobj
  (let ((next (parseobj-next po)))
    (if* (>= next (parseobj-max po))
       then ; must grow it
	    (let ((ostart (parseobj-start po))
		  (oend   (parseobj-end   po)))
	      (let ((nstart (make-array (+ 10 (length ostart))))
		    (nend   (make-array (+ 10 (length ostart)))))
		(dotimes (i (length ostart))
		  (setf (svref nstart i) (svref ostart i))
		  (setf (svref nend   i) (svref oend   i)))
		(setf (parseobj-start po) nstart)
		(setf (parseobj-end   po) nend)
		(setf (parseobj-max   po) (length nstart))
		)))
  
    (setf (svref (parseobj-start po) next) start)
    (setf (svref (parseobj-end   po) next) end)
    (setf (parseobj-next po) (1+ next))
    next))

;;;;;;











(defun parse-url (url)
  ;; look for http://blah/........  and remove the http://blah  part
  ;; look for /...?a=b&c=d  and split out part after the ?
  ;;
  ;; return  values host, url, args
  (let ((urlstart 0)
	(host)
	(args))
    (multiple-value-bind (match whole hostx urlx)
	(match-regexp "^http://\\(.*\\)\\(/\\)" url :shortest t 
		      :return :index)
      (declare (ignore whole))
      (if* match
	 then ; start past the http thing
	      (setq host (buffer-substr url (car hostx) (cdr hostx)))
	      (setq urlstart (car urlx))))
    

    ; look for args
    (multiple-value-bind (match argsx)
	(match-regexp "?.*" url :start urlstart :return :index)
    
      (if* match
	 then (setq args (buffer-substr url (1+ (car argsx)) (cdr argsx))
		    url  (buffer-substr url urlstart (car argsx)))
	 else ; may still have a partial url
	      (if* (> urlstart 0)
		 then (setq url (buffer-substr url urlstart (length url))))
	      ))
  
    (values host url args)))






(defun parse-http-command (buffer end)
  ;; buffer is a string buffer, with 'end' bytes in it.  
  ;; return 3 values
  ;;	command  (kwd naming it or nil if bogus)
  ;;    url      string
  ;;    protocol  (kwd naming it or nil if bogus)
  ;;
  (let ((blankpos)
	(cmd)
	(urlstart))

    ; search for command first
    (dolist (possible *http-command-list* 
	      (return-from parse-http-command nil) ; failure
	      )
      (let ((str (car possible)))
	(if* (buffer-match buffer 0 str)
	   then ; got it
		(setq cmd (cdr possible))
		(setq urlstart (length (car possible)))
		(return))))
    
    
    (setq blankpos (find-it #\space buffer urlstart end))
    
    (if* (eq blankpos urlstart)
       then ; bogus, no url
	    (return-from parse-http-command nil))
    
    
    (if* (null blankpos)
       then ; must be http/0.9
	    (return-from parse-http-command (values cmd 
						    (buffer-substr buffer
								   urlstart
								   end)
						    :http/0.9)))
    
    (let ((url (buffer-substr buffer urlstart blankpos))
	  (prot))
      (if* (buffer-match buffer (1+ blankpos) "HTTP/1.")
	 then (if* (eq #\0 (schar buffer (+ 8 blankpos)))
		 then (setq prot :http/1.0)
	       elseif (eq #\1 (schar buffer (+ 8 blankpos)))
		 then (setq prot :http/1.1)))
      
      (values cmd url prot))))


(eval-when (compile load eval)
  (defun dual-caseify (str)
    ;; create a string with each characater doubled
    ;; but with upper case following the lower case
    (let ((newstr (make-string (* 2 (length str)))))
      (dotimes (i (length str))
	(setf (schar newstr (* 2 i)) (schar str i))
	(setf (schar newstr (1+ (* 2 i))) (char-upcase (schar str i))))
      newstr)))


(defparameter *header-to-slot*
    ;; headers that are stored in specific slots, we create
    ;; a list of objects to help quickly parse those slots
    '#.(let (res)
	(dolist (head *fast-headers*)
	  (push (cons
		 (dual-caseify (concatenate 'string (car head) ":"))
		 (cdr head))
		res))
	res))
      
(defun read-request-headers (req sock buffer)
  ;; read in the headers following the command and put the
  ;; info in the req object
  ;; if an error occurs, then return nil
  ;;
  (let ((last-value-slot nil)
	(last-value-assoc nil)
	(end))
    (loop
      (multiple-value-setq (buffer end)(read-sock-line sock buffer 0))
      (if* (null end) 
	 then ; error
	      (return-from read-request-headers nil))
      (if* (eq 0 end)
	 then ; blank line, end of headers
	      (return t))
    
      (if* (eq #\space (schar buffer 0))
	 then ; continuation of previous line
	      (if* last-value-slot
		 then ; append to value in slot
		      (setf (slot-value req last-value-slot)
			(concatenate 
			    'string
			  (slot-value req last-value-slot)
			  (buffer-substr buffer 0 end)))
	       elseif last-value-assoc
		 then (setf (cdr last-value-assoc)
			(concatenate 'string
			  (cdr last-value-assoc) (buffer-substr buffer 0 end)))
		 else ; continuation with nothing to continue
		      (return-from read-request-headers nil))
	 else ; see if this is one of the special header lines
	    
	      (setq last-value-slot nil)
	      (dolist (possible *header-to-slot*)
		(if* (buffer-match-ci buffer 0 (car possible))
		   then ; store in the slot
			(setf (slot-value req (cdr possible))
			  (concatenate 
			      'string
			    (or (slot-value req (cdr possible)) "")
			    (buffer-substr buffer
					   (1+ (ash (the fixnum 
						      (length (car possible)))
						    -1))
					   end)))
					
			(setq last-value-slot (cdr possible))
			(return)))
	    
	      (if* (null last-value-slot)
		 then ; wasn't a built in header, so put it on
		      ; the alist
		      (let ((colonpos (find-it #\: buffer 0 end))
			    (key)
			    (value))
			  
			(if* (null colonpos)
			   then ; bogus!
				(return-from read-request-headers nil)
			   else (setq key (buffer-substr
					   buffer
					   0
					   colonpos)
				      value
				      (buffer-substr
				       buffer
				       (+ 2 colonpos)
				       end)))
			; downcase the key
			(dotimes (i (length key))
			  (let ((ch (schar key i)))
			    (if* (upper-case-p ch)
			       then (setf (schar key i) 
				      (char-downcase ch)))))
			
			; now add or append
			
			(let* ((alist (alist req))
			       (ent (assoc key alist :test #'equal)))
			  (if* (null ent)
			     then (push (setq ent (cons key "")) alist)
				  (setf (alist req) alist))
			  (setf (cdr ent)
			    (concatenate 'string
			      (cdr ent)
			      value))
			  
			  (setq last-value-assoc ent)
			  )))))))



			

;------ urlencoding
; there are two similar yet distinct encodings for character strings
; that are referred to as "url encodings".
;
; 1. uri's.   rfc2396 describes the format of uri's 
;       uris use only the printing characters.
;	a url can be broken down into a set of a components using
;	a regular expression matcher.
;	There are a set of characters that are reserved:
;		; / ? : @ & = + $ ,
;	Certain reserved characters have special meanings within
;	certain components of the uri.
;	When a reserved character must be used for its normal character
;	meaning within a component, it is expressed in the form %xy 
;	where xy are hex digits representing the characters ascii value.
;
;       The encoding (converting characters to their $xy form) must be
;	done on a component by component basis for a uri.
;	You can't just give a function a complete uri and say "encode this"
;	because if it's a uri then it's already encoded.   You can
;	give a function a filename to be put into a uri and 
;	say "encode this" and that function
;	could look for reserved characters in the filename and convert them
;	to %xy form.
;
; 2. x-www-form-urlencoded
;	when the result of a form is to be sent to the web server
;	it can be sent in one of two ways:
;	1. the "get" method where the form data is passed in the uri
;	    after a "?".
;	2  the "post" method where the data is stored in the body
;	   of the post with an application/x-www-form-urlencoded  
;	   mime type.
;
;	the form data is sent in this format
;		name=value&name2=value2&name3=value3
;	where each of the name,value items is is encoded
;	such that
;	    alphanumerics are unchanged
;	    space turns into "+"
;	    newline turns into "%0d%0a"
;	    these characters are encoded as %xy:
;		+ # ; / ? : @ = & < > %
;	    all non-printing ascii characters are encoded as %xy
;	    printing characters not mentioned are passed through
;	
;


(defun decode-form-urlencoded (str)
  ;; decode the x-www-form-urlencoded string returning a list
  ;; of conses, the car being the name and the cdr the value, for
  ;; each form element
  ;;
  (let (res (max (length str)))
    
    (do ((i 0)
	 (start 0)
	 (name)
	 (max-minus-1 (1- max))
	 (seenpct)
	 (ch))
	((>= i max))
      (setq ch (schar str i))
      
      (let (obj)
	(if* (or (eq ch #\=)
		 (eq ch #\&))
	   then (setq obj (buffer-substr str start i))
		(setq start (1+ i))
	 elseif (eql i max-minus-1)
	   then (setq obj (buffer-substr str start (1+ i)))
	 elseif (and (not seenpct) (or (eq ch #\%)
				       (eq ch #\+)))
	   then (setq seenpct t))
      
	(if* obj
	   then (if* seenpct
		   then (setq obj (un-hex-escape obj)
			      seenpct nil))
	      
		(if* name
		   then (push (cons name obj) res)
			(setq name nil)
		   else (setq name obj))))
      
      (incf i))
    
    res))

(defun un-hex-escape (given)
  ;; convert a string with %xx hex escapes into a string without
  ;; also convert +'s to spaces
  (let ((count 0)
	(seenplus nil)
	(len (length given)))
    
    ; compute the number of %'s (times 2)
    (do ((i 0 (1+ i)))
	((>= i len))
      (let ((ch (schar given i)))
	(if* (eq ch #\%) 
	   then (incf count 2)
		(incf i 2)
	 elseif (eq ch #\+)
	   then (setq seenplus t))))
    
    (if* (and (null seenplus)
	      (eq 0 count))
       then ; move along, nothing to do here
	    (return-from un-hex-escape given))

    (macrolet ((cvt-ch (ch)
		 ;; convert hex character to numeric equiv
		 `(let ((mych (char-code ,ch)))
		    (if* (<= mych #.(char-code #\9))
		       then (- mych #.(char-code #\0))
		       else (+ 9 (logand mych 7))))))
			    
      (let ((str (make-string (- len count))))
	(do ((to 0 (1+ to))
	     (from 0 (1+ from)))
	    ((>= from len))
	  (let ((ch (schar given from)))
	    (if* (eq ch #\%)
	       then (setf (schar str to)
		      (code-char (+ (ash (cvt-ch (schar given (1+ from))) 4)
				    (cvt-ch (schar given (+ 2 from))))))
		    (incf from 2)
	     elseif (eq ch #\+)
	       then (setf (schar str to) #\space)
	       else (setf (schar str to) ch))))
      
	str))))
   
    
    
;------- header value parsing
;
; most headers value this format
;    value
;    value1, value2, value3
;    value; param=val; param2=val
;
; notes: in the comma separated lists, it's legal to use more than one
;	   comma between values in which case the intermediate "null" values
;          are ignored e.g   a,,b is the same as a,b
;
;        the semicolon introduces a parameter, it doesn't end a value.
;        the semicolon has a higher binding power than the comma,
;	 so    A; b=c; d=e, F
;           is two values, A and F, with A having parameters b=c and d=e.
;

(defconstant ch-alpha 0)
(defconstant ch-space 1)
(defconstant ch-sep   2)  ; separators

(defvar *syntax-table*
    (let ((arr (make-array 256 :initial-element ch-alpha)))
      
      ; the default so we don't have to set it
      #+ignore (do ((code (char-code #\!) (1+ code)))
	  ((> code #.(char-code #\~)))
	(setf (svref arr code) ch-alpha))
      
      (setf (svref arr (char-code #\space)) ch-space)
      (setf (svref arr (char-code #\ff)) ch-space)
      (setf (svref arr (char-code #\tab)) ch-space)
      (setf (svref arr (char-code #\return)) ch-space)
      (setf (svref arr (char-code #\newline)) ch-space)
      
      (setf (svref arr (char-code #\,)) ch-sep)
      (setf (svref arr (char-code #\;)) ch-sep)
      (setf (svref arr (char-code #\()) ch-sep)
      
      arr))



(defun header-value-nth (parsed-value n)
  ;; return the nth value in the list of header values
  ;; a value is either a string or a list (:param value  params..)
  ;;
  ;; nil is returned if we've asked for a non-existant element
  ;; (nil is never a valid value).
  ;;
  (if* (and parsed-value (not (consp parsed-value)))
     then (error "bad parsed value ~s" parsed-value))
  
  (let ((val (nth n parsed-value)))
    (if* (atom val)
       then val
       else ; (:param value ...)
	    (cadr val))))
  
	   

(defun ensure-value-parsed (str &optional singlep)
  ;; parse the header value if it hasn't been parsed.
  ;; a parsed value is a cons.. easy to distinguish
  (if* (consp str) 
     then str
     else (parse-header-value str singlep)))


	      

(defun parse-header-value (str &optional singlep (start 0) (end (length str)))
  ;; scan the given string and return either a single value
  ;; or a list of values.
  ;; A single value is a string or (:param value paramval ....) for
  ;; values with parameters.  A paramval is either a string or
  ;; a cons of two strings (name . value)  which are the parameter
  ;; and its value.
  ;;
  ;; if singlep is true then we expect to see a single value which
  ;; main contain commas.  This is seen when Netscape sends
  ;; an if-modified-since header and it may in fact be a bug in 
  ;; Netscape (since parameters aren't defined for if-modified-since's value)
  ;;

  ;; split by comma first
  (let (po res)
    
    (if* singlep
       then ; don't do the comma split, make everything
	    ; one string
	    (setq po (allocate-parseobj))
	    (setf (svref (parseobj-start po) 0) start)
	    (setf (svref (parseobj-end  po) 0) end)
	    (setf (parseobj-next po) 1)
       else (setq po (split-string str #\, t nil nil start end)))
    
		    
    
    ; now for each split, by semicolon
    
    (dotimes (i (parseobj-next po))
      (let ((stindex (parseobj-next po))
	    (params)
	    (thisvalue))
	(split-string str #\; t nil po
		      (svref (parseobj-start po) i)
		      (svref (parseobj-end   po) i))
	; the first object we take whole
	(setq thisvalue (trimmed-parseobj str po stindex))
	(if* (not (equal thisvalue ""))
	   then ; ok, it's real, look for params
		(do ((i (1+ stindex) (1+ i))
		     (max (parseobj-next po))
		     (paramkey nil nil)
		     (paramvalue nil nil))
		    ((>= i max)
		     (setq params (nreverse params))
		     )
		  
		  ; split the param by =
		  (split-string str #\= t 1 po
				(svref (parseobj-start po) i)
				(svref (parseobj-end   po) i))
		  (setq paramkey (trimmed-parseobj str po max))
		  (if* (> (parseobj-next po) (1+ max))
		     then ; must have been an equal
			  (setq paramvalue (trimmed-parseobj str po
							     (1+ max))))
		  (push (if* paramvalue
			   then (cons paramkey paramvalue)
			   else paramkey)
			params)
		  
		  (setf (parseobj-next po) max))
		
		(push (if* params
			 then `(:param ,thisvalue
				       ,@params)
			 else thisvalue)
		      res))))
    
    (free-parseobj po)
    
    (nreverse res)))
    
	
		
		
(defun trimmed-parseobj (str po index)
  ;; return the string pointed to by the given index in 
  ;; the parseobj -- trimming blanks around both sides
  
  (let ((start (svref (parseobj-start po) index))
	(end   (svref (parseobj-end   po) index)))
    
    ;; trim left
    (loop
      (if* (>= start end)
	 then (return-from trimmed-parseobj "")
	 else (let ((ch (schar str start)))
		(if* (eq ch-space (svref *syntax-table*
				       (char-code ch)))
		   then (incf start)
		   else (return)))))
    
    ; trim right
    (loop
      (decf end)
      (let ((ch (schar str end)))
	(if* (not (eq ch-sep (svref *syntax-table* (char-code ch))))
	   then (incf end)
		(return))))
    
    ; make string
    (let ((newstr (make-string (- end start))))
      (dotimes (i (- end start))
	(setf (schar newstr i) 
	  (schar str (+ start i))))
      
      newstr)))
    
    
		  
		  
				
		  
    

(defun split-string (str split &optional 
			       magic-parens 
			       count 
			       parseobj
			       (start 0) 
			       (end  (length str)))
  ;; divide the string where the character split occurs
  ;; return the results in parseobj object
  (let ((po (or parseobj (allocate-parseobj)))
	(st start)
	)
    ; states
    ; 0 initial, scanning for interesting char or end
    (loop
      (if* (>= start end)
	 then (add-to-parseobj po st start)
	      (return)
	 else (let ((ch (schar str start)))
		
		(if* (eq ch split)
		   then ; end this one
			(add-to-parseobj po st start)
			(setq st (incf start))
			(if* (and count (zerop (decf count)))
			   then ; get out now
				(add-to-parseobj po st end)
				(return))
		 elseif (and magic-parens (eq ch #\())
		   then ; scan until matching paren
			(let ((count 1))
			  (loop
			    (incf start)
			    (if* (>= start end)
			       then (return)
			       else (setq ch (schar str start))
				    (if* (eq ch #\))
				       then (if* (zerop (decf count))
					       then (return))
				     elseif (eq ch #\()
				       then (incf count)))))
			   
			(if* (>= start end)
			   then (add-to-parseobj po st start)
				(return))
		   else (incf start)))))
    po))
  
(defun split-into-words (str)
  ;; split the given string into words (items separated by white space)
  ;;
  (let ((state 0)
	(i 0)
	(len (length str))
	(start nil)
	(res)
	(ch)
	(spacep))
    (loop
      (if* (>= i len)
	 then (setq ch #\space)
	 else (setq ch (char str i)))
      (setq spacep (eq ch-space (svref *syntax-table* (char-code ch))))
      
      (case state
	(0  ; looking for non-space
	 (if* (not spacep)
	    then (setq start i
		       state 1)))
	(1  ; have left anchor, looking for space
	 (if* spacep
	    then (push (subseq str start i) res)
		 (setq state 0))))
      (if* (>= i len) then (return))
      (incf i))
    (nreverse res)))
		 

;; this isn't needed while the web server is running, it just
;; needs to be run periodically as new mime types are introduced.
#+ignore
(defun generate-mime-table (&optional (file "/etc/mimepa.types"))
  ;; generate a file type to mime type table based on file type
  (let (res)
    (with-open-file (p file :direction :input)
      (loop
	(let ((line (read-line p nil nil)))
	  (if* (null line) then (return))
	  (if* (and (> (length line) 0)
		    (eq #\# (schar line 0)))
	     thenret ; comment
	     else ; real stuff
		  (let ((data (split-into-words line)))
		    (if* data then (push data res)))))))
    (nreverse res)))
  
  
					 
			     
;------- base64

; encoding algorithm:
  ;; each character is an 8 bit value.
  ;; three 8 bit values (24 bits) are turned into four 6-bit values (0-63)
  ;; which are then encoded as characters using the following mapping.
  ;; Zero values are added to the end of the string in order to get
  ;; a size divisible by 3.
  ;; 
  ;; encoding
  ;; 0-25   A-Z
  ;; 26-51  a-z
  ;; 52-61  0-9
  ;; 62     +
  ;; 63     /
  ;;

    

(defvar *base64-decode* 
    (let ((arr (make-array 128 :element-type '(unsigned-byte 8))))
      (do ((i 0 (1+ i))
	   (ch (char-code #\A) (1+ ch)))
	  ((> ch #.(char-code #\Z)))
	(setf (aref arr ch) i))
      (do ((i 26 (1+ i))
	   (ch (char-code #\a) (1+ ch)))
	  ((> ch #.(char-code #\z)))
	(setf (aref arr ch) i))
      (do ((i 52 (1+ i))
	   (ch (char-code #\0) (1+ ch)))
	  ((> ch #.(char-code #\9)))
	(setf (aref arr ch) i))
      (setf (aref arr (char-code #\+)) 62)
      (setf (aref arr (char-code #\/)) 62)
      
      arr))

(defun base64-decode (string)
  ;; given a base64 string, return it decoded.
  ;; the result will not be a simple string
  (let ((res (make-array 20 :element-type 'character
			 :fill-pointer 0
			 :adjustable t))
	(arr *base64-decode*))
    (declare (type (simple-array (unsigned-byte 8) 128) arr))
    (do ((i 0 (+ i 4))
	 (cha)
	 (chb))
	((>= i (length string)))
      (let ((val (+ (ash (aref arr (char-code (char string i))) 18)
		    (ash (aref arr (char-code (char string (+ i 1)))) 12)
		    (ash (aref arr (char-code 
				    (setq cha (char string (+ i 2)))))
			 6)
		    (aref arr (char-code 
			       (setq chb (char string (+ i 3))))))))
	(vector-push-extend (code-char (ash val -16)) res)
	;; when the original size wasn't a mult of 3 there may be
	;; non-characters left over
	(if* (not (eq cha #\=))
	   then (vector-push-extend (code-char (logand #xff (ash val -8))) res))
	(if* (not (eq chb #\=))
	   then (vector-push-extend (code-char (logand #xff val)) res))))
    res))

	

      
	      
	      
  
  
       

