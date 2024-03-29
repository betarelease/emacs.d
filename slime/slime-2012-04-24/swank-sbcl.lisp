;;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; swank-sbcl.lisp --- SLIME backend for SBCL.
;;;
;;; Created 2003, Daniel Barlow <dan@metacircles.com>
;;;
;;; This code has been placed in the Public Domain.  All warranties are
;;; disclaimed.

;;; Requires the SB-INTROSPECT contrib.

;;; Administrivia

(in-package :swank-backend)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require 'sb-bsd-sockets)
  (require 'sb-introspect)
  (require 'sb-posix)
  (require 'sb-cltl2)
  (import-from :sb-gray *gray-stream-symbols* :swank-backend))

(declaim (optimize (debug 2) 
                   (sb-c::insert-step-conditions 0)
                   (sb-c::insert-debug-catch 0)
                   (sb-c::merge-tail-calls 2)))

;;; backwards compability tests

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Generate a form suitable for testing for stepper support (0.9.17)
  ;; with #+.
  (defun sbcl-with-new-stepper-p ()
    (with-symbol 'enable-stepping 'sb-impl))
  ;; Ditto for weak hash-tables
  (defun sbcl-with-weak-hash-tables ()
    (with-symbol 'hash-table-weakness 'sb-ext))
  ;; And for xref support (1.0.1)
  (defun sbcl-with-xref-p ()
    (with-symbol 'who-calls 'sb-introspect))
  ;; ... for restart-frame support (1.0.2)
  (defun sbcl-with-restart-frame ()
    (with-symbol 'frame-has-debug-tag-p 'sb-debug)))

;;; swank-mop

(import-swank-mop-symbols :sb-mop '(:slot-definition-documentation))

(defun swank-mop:slot-definition-documentation (slot)
  (sb-pcl::documentation slot t))

;;; Connection info

(defimplementation lisp-implementation-type-name ()
  "sbcl")

;; Declare return type explicitly to shut up STYLE-WARNINGS about
;; %SAP-ALIEN in ENABLE-SIGIO-ON-FD below.
(declaim (ftype (function () (values (signed-byte 32) &optional)) getpid))
(defimplementation getpid ()
  (sb-posix:getpid))

;;; UTF8

(defimplementation string-to-utf8 (string)
  (sb-ext:string-to-octets string :external-format :utf8))

(defimplementation utf8-to-string (octets)
  (sb-ext:octets-to-string octets :external-format :utf8))

;;; TCP Server

(defimplementation preferred-communication-style ()
  (cond
    ;; fixme: when SBCL/win32 gains better select() support, remove
    ;; this.
    ((member :sb-thread *features*) :spawn)
    ((member :win32 *features*) nil)
    (t :fd-handler)))

(defun resolve-hostname (name)
  (car (sb-bsd-sockets:host-ent-addresses
        (sb-bsd-sockets:get-host-by-name name))))

(defimplementation create-socket (host port &key backlog)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
			       :type :stream
			       :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket (resolve-hostname host) port)
    (sb-bsd-sockets:socket-listen socket (or backlog 5))
    socket))

(defimplementation local-port (socket)
  (nth-value 1 (sb-bsd-sockets:socket-name socket)))

(defimplementation close-socket (socket)
  (sb-sys:invalidate-descriptor (socket-fd socket))
  (sb-bsd-sockets:socket-close socket))

(defimplementation accept-connection (socket &key
                                      external-format
                                      buffering timeout)
  (declare (ignore timeout))
  (make-socket-io-stream (accept socket) external-format 
                         (ecase buffering
                           ((t :full) :full)
                           ((nil :none) :none)
                           ((:line) :line))))

#-win32
(defimplementation install-sigint-handler (function)
  (sb-sys:enable-interrupt sb-unix:sigint 
                           (lambda (&rest args)
                             (declare (ignore args))
                             (sb-sys:invoke-interruption 
                              (lambda ()
                                (sb-sys:with-interrupts 
                                  (funcall function)))))))

(defvar *sigio-handlers* '()
  "List of (key . fn) pairs to be called on SIGIO.")

(defun sigio-handler (signal code scp)
  (declare (ignore signal code scp))
  (mapc (lambda (handler)
          (funcall (the function (cdr handler))))
        *sigio-handlers*))

(defun set-sigio-handler ()
  (sb-sys:enable-interrupt sb-unix:sigio (lambda (signal code scp)
                                           (sigio-handler signal code scp))))

(defun enable-sigio-on-fd (fd)
  (sb-posix::fcntl fd sb-posix::f-setfl sb-posix::o-async)
  (sb-posix::fcntl fd sb-posix::f-setown (getpid))
  (values))

(defimplementation add-sigio-handler (socket fn)
  (set-sigio-handler)
  (let ((fd (socket-fd socket)))
    (enable-sigio-on-fd fd)
    (push (cons fd fn) *sigio-handlers*)))

(defimplementation remove-sigio-handlers (socket)
  (let ((fd (socket-fd socket)))
    (setf *sigio-handlers* (delete fd *sigio-handlers* :key #'car))
    (sb-sys:invalidate-descriptor fd))
  (close socket))

(defimplementation add-fd-handler (socket fun)
  (let ((fd (socket-fd socket))
        (handler nil))
    (labels ((add ()
               (setq handler (sb-sys:add-fd-handler fd :input #'run)))
             (run (fd)
               (sb-sys:remove-fd-handler handler) ; prevent recursion
               (unwind-protect 
                    (funcall fun)
                 (when (sb-unix:unix-fstat fd) ; still open?
                   (add)))))
      (add))))

(defimplementation remove-fd-handlers (socket)
  (sb-sys:invalidate-descriptor (socket-fd socket)))

(defimplementation socket-fd (socket)
  (etypecase socket
    (fixnum socket)
    (sb-bsd-sockets:socket (sb-bsd-sockets:socket-file-descriptor socket))
    (file-stream (sb-sys:fd-stream-fd socket))))

(defimplementation command-line-args ()
  sb-ext:*posix-argv*)

(defimplementation dup (fd)
  (sb-posix:dup fd))

(defvar *wait-for-input-called*)

(defimplementation wait-for-input (streams &optional timeout)
  (assert (member timeout '(nil t)))
  (when (boundp '*wait-for-input-called*)
    (setq *wait-for-input-called* t))
  (let ((*wait-for-input-called* nil))
    (loop
      (let ((ready (remove-if-not #'input-ready-p streams)))
        (when ready (return ready)))
      (when (check-slime-interrupts)
        (return :interrupt))
      (when *wait-for-input-called*
        (return :interrupt))
      (when timeout
        (return nil))
      (sleep 0.1))))

(defun fd-stream-input-buffer-empty-p (stream)
  (let ((buffer (sb-impl::fd-stream-ibuf stream)))
    (or (not buffer)
        (= (sb-impl::buffer-head buffer)
           (sb-impl::buffer-tail buffer)))))

#-win32
(defun input-ready-p (stream)
  (or (not (fd-stream-input-buffer-empty-p stream))
      #+#.(swank-backend:with-symbol 'fd-stream-fd-type 'sb-impl)
      (eq :regular (sb-impl::fd-stream-fd-type stream))
      (not (sb-impl::sysread-may-block-p stream))))

#+win32
(progn
  (defun input-ready-p (stream)
    (or (not (fd-stream-input-buffer-empty-p stream))
        (handle-listen (sockint::fd->handle (sb-impl::fd-stream-fd stream)))))

  (sb-alien:define-alien-routine ("WSACreateEvent" wsa-create-event)
      sb-win32:handle)
  
  (sb-alien:define-alien-routine ("WSACloseEvent" wsa-close-event)
      sb-alien:int 
    (event sb-win32:handle))
  
  (defconstant +fd-read+ #.(ash 1 0))
  (defconstant +fd-close+ #.(ash 1 5))
  
  (sb-alien:define-alien-routine ("WSAEventSelect" wsa-event-select)
      sb-alien:int 
    (fd sb-alien:int) 
    (handle sb-win32:handle)
    (mask sb-alien:long))

  (sb-alien:load-shared-object "kernel32.dll")
  (sb-alien:define-alien-routine ("WaitForSingleObjectEx" 
                                  wait-for-single-object-ex)
      sb-alien:int
    (event sb-win32:handle)
    (milliseconds sb-alien:long)
    (alertable sb-alien:int))

  ;; see SB-WIN32:HANDLE-LISTEN
  (defun handle-listen (handle)
    (sb-alien:with-alien ((avail sb-win32:dword)
                          (buf (array char #.sb-win32::input-record-size)))
      (unless (zerop (sb-win32:peek-named-pipe handle nil 0 nil 
                                               (sb-alien:alien-sap
                                                (sb-alien:addr avail))
                                               nil))
        (return-from handle-listen (plusp avail)))

      (unless (zerop (sb-win32:peek-console-input handle
                                                  (sb-alien:alien-sap buf)
                                                  sb-win32::input-record-size 
                                                  (sb-alien:alien-sap 
                                                   (sb-alien:addr avail))))
        (return-from handle-listen (plusp avail))))

    (let ((event (wsa-create-event)))
      (wsa-event-select handle event (logior +fd-read+ +fd-close+))
      (let ((val (wait-for-single-object-ex event 0 0)))
        (wsa-close-event event)
        (unless (= val -1)
          (return-from handle-listen (zerop val)))))

    nil)

  )

(defvar *external-format-to-coding-system*
  '((:iso-8859-1 
     "latin-1" "latin-1-unix" "iso-latin-1-unix" 
     "iso-8859-1" "iso-8859-1-unix")
    (:utf-8 "utf-8" "utf-8-unix")
    (:euc-jp "euc-jp" "euc-jp-unix")
    (:us-ascii "us-ascii" "us-ascii-unix")))

;; C.f. R.M.Kreuter in <20536.1219412774@progn.net> on sbcl-general,
;; 2008-08-22.
(defvar *physical-pathname-host* (pathname-host (user-homedir-pathname)))

(defimplementation filename-to-pathname (filename)
  (sb-ext:parse-native-namestring filename *physical-pathname-host*))

(defimplementation find-external-format (coding-system)
  (car (rassoc-if (lambda (x) (member coding-system x :test #'equal))
                  *external-format-to-coding-system*)))

(defun make-socket-io-stream (socket external-format buffering)
  (let ((args `(,@()
                :output t
                :input t
                :element-type ,(if external-format
                                   'character 
                                   '(unsigned-byte 8))
                :buffering ,buffering
                ,@(cond ((and external-format (sb-int:featurep :sb-unicode))
                         `(:external-format ,external-format))
                        (t '()))
                :serve-events ,(eq :fd-handler
                                   (swank-value '*communication-style* t))
                  ;; SBCL < 1.0.42.43 doesn't support :SERVE-EVENTS
                  ;; argument.
                :allow-other-keys t)))
  (apply #'sb-bsd-sockets:socket-make-stream socket args)))

(defun accept (socket)
  "Like socket-accept, but retry on EAGAIN."
  (loop (handler-case
            (return (sb-bsd-sockets:socket-accept socket))
          (sb-bsd-sockets:interrupted-error ()))))


;;;; Support for SBCL syntax

;;; SBCL's source code is riddled with #! reader macros.  Also symbols
;;; containing `!' have special meaning.  We have to work long and
;;; hard to be able to read the source.  To deal with #! reader
;;; macros, we use a special readtable.  The special symbols are
;;; converted by a condition handler.

(defun feature-in-list-p (feature list)
  (etypecase feature
    (symbol (member feature list :test #'eq))
    (cons (flet ((subfeature-in-list-p (subfeature)
		   (feature-in-list-p subfeature list)))
	    (ecase (first feature)
	      (:or  (some  #'subfeature-in-list-p (rest feature)))
	      (:and (every #'subfeature-in-list-p (rest feature)))
	      (:not (destructuring-bind (e) (cdr feature)
                      (not (subfeature-in-list-p e)))))))))

(defun shebang-reader (stream sub-character infix-parameter)
  (declare (ignore sub-character))
  (when infix-parameter
    (error "illegal read syntax: #~D!" infix-parameter))
  (let ((next-char (read-char stream)))
    (unless (find next-char "+-")
      (error "illegal read syntax: #!~C" next-char))
    ;; When test is not satisfied
    ;; FIXME: clearer if order of NOT-P and (NOT NOT-P) were reversed? then
    ;; would become "unless test is satisfied"..
    (when (let* ((*package* (find-package "KEYWORD"))
		 (*read-suppress* nil)
		 (not-p (char= next-char #\-))
		 (feature (read stream)))
	    (if (feature-in-list-p feature *features*)
		not-p
		(not not-p)))
      ;; Read (and discard) a form from input.
      (let ((*read-suppress* t))
	(read stream t nil t))))
 (values))

(defvar *shebang-readtable*
  (let ((*readtable* (copy-readtable nil)))
    (set-dispatch-macro-character #\# #\!
                                  (lambda (s c n) (shebang-reader s c n))
                                  *readtable*)
    *readtable*))

(defun shebang-readtable ()
  *shebang-readtable*)

(defun sbcl-package-p (package)
  (let ((name (package-name package)))
    (eql (mismatch "SB-" name) 3)))

(defun sbcl-source-file-p (filename)
  (when filename
    (loop for (nil pattern) in (logical-pathname-translations "SYS")
          thereis (pathname-match-p filename pattern))))

(defun guess-readtable-for-filename (filename)
  (if (sbcl-source-file-p filename)
      (shebang-readtable)
      *readtable*))

(defvar *debootstrap-packages* t)

(defun call-with-debootstrapping (fun)
  (handler-bind ((sb-int:bootstrap-package-not-found
                  #'sb-int:debootstrap-package))
    (funcall fun)))

(defmacro with-debootstrapping (&body body)
  `(call-with-debootstrapping (lambda () ,@body)))

(defimplementation call-with-syntax-hooks (fn)
  (cond ((and *debootstrap-packages*
              (sbcl-package-p *package*))
         (with-debootstrapping (funcall fn)))
        (t
         (funcall fn))))

(defimplementation default-readtable-alist ()
  (let ((readtable (shebang-readtable)))
    (loop for p in (remove-if-not #'sbcl-package-p (list-all-packages))
          collect (cons (package-name p) readtable))))

;;; Utilities

(defun swank-value (name &optional errorp)
  ;; Easy way to refer to symbol values in SWANK, which doesn't yet exist when
  ;; this is file is loaded.
  (let ((symbol (find-symbol (string name) :swank)))
    (if (and symbol (or errorp (boundp symbol)))
        (symbol-value symbol)
        (when errorp
          (error "~S does not exist in SWANK." name)))))

#+#.(swank-backend:with-symbol 'function-lambda-list 'sb-introspect)
(defimplementation arglist (fname)
  (sb-introspect:function-lambda-list fname))

#-#.(swank-backend:with-symbol 'function-lambda-list 'sb-introspect)
(defimplementation arglist (fname)
  (sb-introspect:function-arglist fname))

(defimplementation function-name (f)
  (check-type f function)
  (sb-impl::%fun-name f))

(defmethod declaration-arglist ((decl-identifier (eql 'optimize)))
  (flet ((ensure-list (thing) (if (listp thing) thing (list thing))))
    (let* ((flags (sb-cltl2:declaration-information decl-identifier)))
      (if flags
          ;; Symbols aren't printed with package qualifiers, but the
          ;; FLAGS would have to be fully qualified when used inside a
          ;; declaration. So we strip those as long as there's no
          ;; better way. (FIXME)
          `(&any ,@(remove-if-not
                    #'(lambda (qualifier)
                        (find-symbol (symbol-name (first qualifier)) :cl))
                    flags :key #'ensure-list))
          (call-next-method)))))

#+#.(swank-backend:with-symbol 'deftype-lambda-list 'sb-introspect)
(defmethod type-specifier-arglist :around (typespec-operator)
  (multiple-value-bind (arglist foundp)
      (sb-introspect:deftype-lambda-list typespec-operator)
    (if foundp arglist (call-next-method))))


(defvar *buffer-name* nil)
(defvar *buffer-tmpfile* nil)
(defvar *buffer-offset*)
(defvar *buffer-substring* nil)

(defvar *previous-compiler-condition* nil
  "Used to detect duplicates.")

(defun handle-notification-condition (condition)
  "Handle a condition caused by a compiler warning.
This traps all compiler conditions at a lower-level than using
C:*COMPILER-NOTIFICATION-FUNCTION*. The advantage is that we get to
craft our own error messages, which can omit a lot of redundant
information."
  (unless (or (eq condition *previous-compiler-condition*))
    ;; First resignal warnings, so that outer handlers -- which may choose to
    ;; muffle this -- get a chance to run.
    (when (typep condition 'warning)
      (signal condition))
    (setq *previous-compiler-condition* condition)
    (signal-compiler-condition (real-condition condition)
                               (sb-c::find-error-context nil))))

(defun signal-compiler-condition (condition context)
  (signal (make-condition
           'compiler-condition
           :original-condition condition
           :severity (etypecase condition
                       (sb-ext:compiler-note :note)
                       (sb-c:compiler-error  :error)
                       (reader-error         :read-error)
                       (error                :error)
                       #+#.(swank-backend:with-symbol redefinition-warning 
                             sb-kernel)
                       (sb-kernel:redefinition-warning
                                             :redefinition)
                       (style-warning        :style-warning)
                       (warning              :warning))
           :references (condition-references condition)
           :message (brief-compiler-message-for-emacs condition)
           :source-context (compiler-error-context context)
           :location (compiler-note-location condition context))))

(defun real-condition (condition)
  "Return the encapsulated condition or CONDITION itself."
  (typecase condition
    (sb-int:encapsulated-condition (sb-int:encapsulated-condition condition))
    (t condition)))

(defun condition-references (condition)
  (if (typep condition 'sb-int:reference-condition)
      (externalize-reference
       (sb-int:reference-condition-references condition))))

(defun compiler-note-location (condition context)
  (flet ((bailout ()
           (return-from compiler-note-location
             (make-error-location "No error location available"))))
    (cond (context
           (locate-compiler-note
            (sb-c::compiler-error-context-file-name context)
            (compiler-source-path context)
            (sb-c::compiler-error-context-original-source context)))
          ((typep condition 'reader-error)
           (let* ((stream (stream-error-stream condition))
                  (file   (pathname stream)))
             (unless (open-stream-p stream)
               (bailout))
             (if (compiling-from-buffer-p file)
                 ;; The stream position for e.g. "comma not inside
                 ;; backquote" is at the character following the
                 ;; comma, :offset is 0-based, hence the 1-.
                 (make-location (list :buffer *buffer-name*)
                                (list :offset *buffer-offset*
                                      (1- (file-position stream))))
                 (progn
                   (assert (compiling-from-file-p file))
                   ;; No 1- because :position is 1-based.
                   (make-location (list :file (namestring file))
                                  (list :position (file-position stream)))))))
          (t (bailout)))))

(defun compiling-from-buffer-p (filename)
  (and *buffer-name*
       ;; The following is to trigger COMPILING-FROM-GENERATED-CODE-P
       ;; in LOCATE-COMPILER-NOTE, and allows handling nested
       ;; compilation from eg. hitting C-C on (eval-when ... (require ..))).
       ;;
       ;; PROBE-FILE to handle tempfile directory being a symlink.
       (pathnamep filename)
       (let ((true1 (probe-file filename))
             (true2 (probe-file *buffer-tmpfile*)))
         (and true1 (equal true1 true2)))))

(defun compiling-from-file-p (filename)
  (and (pathnamep filename)
       (or (null *buffer-name*)
           (null *buffer-tmpfile*)
           (let ((true1 (probe-file filename))
                 (true2 (probe-file *buffer-tmpfile*)))
             (not (and true1 (equal true1 true2)))))))

(defun compiling-from-generated-code-p (filename source)
  (and (eq filename :lisp) (stringp source)))

(defun locate-compiler-note (file source-path source)
  (cond ((compiling-from-buffer-p file)
         (make-location (list :buffer *buffer-name*)
                        (list :offset  *buffer-offset* 
                              (source-path-string-position
                               source-path *buffer-substring*))))
        ((compiling-from-file-p file)
         (make-location (list :file (namestring file))
                        (list :position (1+ (source-path-file-position
                                             source-path file)))))
        ((compiling-from-generated-code-p file source)
         (make-location (list :source-form source)
                        (list :position 1)))
        (t
         (error "unhandled case in compiler note ~S ~S ~S" 
                file source-path source))))

(defun brief-compiler-message-for-emacs (condition)
  "Briefly describe a compiler error for Emacs.
When Emacs presents the message it already has the source popped up
and the source form highlighted. This makes much of the information in
the error-context redundant."
  (let ((sb-int:*print-condition-references* nil))
    (princ-to-string condition)))

(defun compiler-error-context (error-context)
  "Describe a compiler error for Emacs including context information."
  (declare (type (or sb-c::compiler-error-context null) error-context))
  (multiple-value-bind (enclosing source)
      (if error-context
          (values (sb-c::compiler-error-context-enclosing-source error-context)
                  (sb-c::compiler-error-context-source error-context)))
    (and (or enclosing source)
         (format nil "~@[--> ~{~<~%--> ~1:;~A~> ~}~%~]~@[~{==>~%~A~%~}~]"
                 enclosing source))))

(defun compiler-source-path (context)
  "Return the source-path for the current compiler error.
Returns NIL if this cannot be determined by examining internal
compiler state."
  (cond ((sb-c::node-p context)
         (reverse
          (sb-c::source-path-original-source
           (sb-c::node-source-path context))))
        ((sb-c::compiler-error-context-p context)
         (reverse
          (sb-c::compiler-error-context-original-source-path context)))))

(defimplementation call-with-compilation-hooks (function)
  (declare (type function function))
  (handler-bind
      ;; N.B. Even though these handlers are called HANDLE-FOO they
      ;; actually decline, i.e. the signalling of the original
      ;; condition continues upward.
      ((sb-c:fatal-compiler-error #'handle-notification-condition)
       (sb-c:compiler-error       #'handle-notification-condition)
       (sb-ext:compiler-note      #'handle-notification-condition)
       (error                     #'handle-notification-condition)
       (warning                   #'handle-notification-condition))
    (funcall function)))


(defvar *trap-load-time-warnings* t)

(defun compiler-policy (qualities)
  "Return compiler policy qualities present in the QUALITIES alist.
QUALITIES is an alist with (quality . value)"
  #+#.(swank-backend:with-symbol 'restrict-compiler-policy 'sb-ext)
  (loop with policy = (sb-ext:restrict-compiler-policy)
        for (quality) in qualities
        collect (cons quality
                      (or (cdr (assoc quality policy))
                          0))))

(defun (setf compiler-policy) (policy)
  (declare (ignorable policy))
  #+#.(swank-backend:with-symbol 'restrict-compiler-policy 'sb-ext)
  (loop for (qual . value) in policy
        do (sb-ext:restrict-compiler-policy qual value)))

(defmacro with-compiler-policy (policy &body body)
  (let ((current-policy (gensym)))
    `(let ((,current-policy (compiler-policy ,policy)))
       (setf (compiler-policy) ,policy)
       (unwind-protect (progn ,@body)
         (setf (compiler-policy) ,current-policy)))))

(defimplementation swank-compile-file (input-file output-file 
                                       load-p external-format
                                       &key policy)
  (multiple-value-bind (output-file warnings-p failure-p)
      (with-compiler-policy policy
        (with-compilation-hooks ()
          (compile-file input-file :output-file output-file
                        :external-format external-format)))
    (values output-file warnings-p
            (or failure-p
                (when load-p
                  ;; Cache the latest source file for definition-finding.
                  (source-cache-get input-file 
                                    (file-write-date input-file))
                  (not (load output-file)))))))

;;;; compile-string

;;; We copy the string to a temporary file in order to get adequate
;;; semantics for :COMPILE-TOPLEVEL and :LOAD-TOPLEVEL EVAL-WHEN forms
;;; which the previous approach using
;;;     (compile nil `(lambda () ,(read-from-string string)))
;;; did not provide.

(locally (declare (sb-ext:muffle-conditions sb-ext:compiler-note))

(sb-alien:define-alien-routine (#-win32 "tempnam" #+win32 "_tempnam" tempnam)
    sb-alien:c-string
  (dir sb-alien:c-string)
  (prefix sb-alien:c-string))

)

(defun temp-file-name ()
  "Return a temporary file name to compile strings into."
  (tempnam nil nil))

(defimplementation swank-compile-string (string &key buffer position filename
                                         policy)
  (let ((*buffer-name* buffer)
        (*buffer-offset* position)
        (*buffer-substring* string)
        (*buffer-tmpfile* (temp-file-name)))
    (flet ((load-it (filename)
             (when filename (load filename)))
           (compile-it (cont)
             (with-compilation-hooks ()
               (with-compilation-unit
                   (:source-plist (list :emacs-buffer buffer
                                        :emacs-filename filename
                                        :emacs-string string
                                        :emacs-position position)
                    :source-namestring filename
                    :allow-other-keys t)
                 (multiple-value-bind (output-file warningsp failurep)
                     (compile-file *buffer-tmpfile* :external-format :utf-8)
                   (declare (ignore warningsp))
                   (unless failurep
                     (funcall cont output-file)))))))
      (with-open-file (s *buffer-tmpfile* :direction :output :if-exists :error
                         :external-format :utf-8)
        (write-string string s))
      (unwind-protect
           (with-compiler-policy policy
            (if *trap-load-time-warnings*
                (compile-it #'load-it)
                (load-it (compile-it #'identity))))
        (ignore-errors
          (delete-file *buffer-tmpfile*)
          (delete-file (compile-file-pathname *buffer-tmpfile*)))))))

;;;; Definitions

(defparameter *definition-types*
  '(:variable defvar
    :constant defconstant
    :type deftype
    :symbol-macro define-symbol-macro
    :macro defmacro
    :compiler-macro define-compiler-macro
    :function defun
    :generic-function defgeneric
    :method defmethod
    :setf-expander define-setf-expander
    :structure defstruct
    :condition define-condition
    :class defclass
    :method-combination define-method-combination
    :package defpackage
    :transform :deftransform
    :optimizer :defoptimizer
    :vop :define-vop
    :source-transform :define-source-transform)
  "Map SB-INTROSPECT definition type names to Slime-friendly forms")

(defun definition-specifier (type name)
  "Return a pretty specifier for NAME representing a definition of type TYPE."
  (if (and (symbolp name)
           (eq type :function)
           (sb-int:info :function :ir1-convert name))
      :def-ir1-translator
      (getf *definition-types* type)))

(defun make-dspec (type name source-location)
  (let ((spec (definition-specifier type name))
        (desc (sb-introspect::definition-source-description source-location)))
    (if (eq :define-vop spec)
        ;; The first part of the VOP description is the name of the template
        ;; -- which is actually good information and often long. So elide the
        ;; original name in favor of making the interesting bit more visible.
        ;;
        ;; The second part of the VOP description is the associated
        ;; compiler note, or NIL -- which is quite uninteresting and
        ;; confuses the eye when reading the actual name which usually
        ;; has a worthwhile postfix. So drop the note.
        (list spec (car desc))
        (list* spec name desc))))

(defimplementation find-definitions (name)
  (loop for type in *definition-types* by #'cddr
        for defsrcs = (sb-introspect:find-definition-sources-by-name name type)
        append (loop for defsrc in defsrcs collect
                     (list (make-dspec type name defsrc)
                           (converting-errors-to-error-location
                             (definition-source-for-emacs defsrc
                                 type name))))))

(defimplementation find-source-location (obj)
  (flet ((general-type-of (obj)
           (typecase obj
             (method             :method)
             (generic-function   :generic-function)
             (function           :function)
             (structure-class    :structure-class)
             (class              :class)
             (method-combination :method-combination)
             (package            :package)
             (condition          :condition)
             (structure-object   :structure-object)
             (standard-object    :standard-object)
             (t                  :thing)))
         (to-string (obj)
           (typecase obj
             ;; Packages are possibly named entities.
             (package (princ-to-string obj)) 
             ((or structure-object standard-object condition)
              (with-output-to-string (s)
                (print-unreadable-object (obj s :type t :identity t))))
             (t (princ-to-string obj)))))
    (converting-errors-to-error-location
      (let ((defsrc (sb-introspect:find-definition-source obj)))
        (definition-source-for-emacs defsrc
                                     (general-type-of obj)
                                     (to-string obj))))))


(defun categorize-definition-source (definition-source)
  (with-struct (sb-introspect::definition-source-
                   pathname form-path character-offset plist)
      definition-source
    (cond ((getf plist :emacs-buffer) :buffer)
          ((and pathname (or form-path character-offset)) :file)
          (pathname :file-without-position)
          (t :invalid))))

(defun definition-source-for-emacs (definition-source type name)
  (with-struct (sb-introspect::definition-source-
                   pathname form-path character-offset plist
                   file-write-date)
      definition-source
    (ecase (categorize-definition-source definition-source)
      (:buffer
       (destructuring-bind (&key emacs-buffer emacs-position emacs-directory
                                 emacs-string &allow-other-keys)
           plist
         (let ((*readtable* (guess-readtable-for-filename emacs-directory)))
           (multiple-value-bind (start end)
               (if form-path
                   (with-debootstrapping
                     (source-path-string-position form-path emacs-string))
                   (values character-offset most-positive-fixnum))
             (make-location
              `(:buffer ,emacs-buffer)
              `(:offset ,emacs-position ,start)
              `(:snippet
                ,(subseq emacs-string
                         start
                         (min end (+ start *source-snippet-size*)))))))))
      (:file
       (let* ((namestring (namestring (translate-logical-pathname pathname)))
              (pos (if form-path
                       (source-file-position namestring file-write-date 
                                             form-path)
                       character-offset))
              (snippet (source-hint-snippet namestring file-write-date pos)))
         (make-location `(:file ,namestring)
                        ;; /file positions/ in Common Lisp start from
                        ;; 0, buffer positions in Emacs start from 1.
                        `(:position ,(1+ pos))
                        `(:snippet ,snippet))))
      (:file-without-position
       (make-location `(:file ,(namestring 
                                (translate-logical-pathname pathname)))
                      '(:position 1)
                      (when (eql type :function)
                        `(:snippet ,(format nil "(defun ~a " 
                                            (symbol-name name))))))
      (:invalid
       (error "DEFINITION-SOURCE of ~A ~A did not contain ~
               meaningful information."
              (string-downcase type) name)))))

(defun source-file-position (filename write-date form-path)
  (let ((source (get-source-code filename write-date))
        (*readtable* (guess-readtable-for-filename filename)))
    (with-debootstrapping
      (source-path-string-position form-path source))))

(defun source-hint-snippet (filename write-date position)
  (read-snippet-from-string (get-source-code filename write-date) position))

(defun function-source-location (function &optional name)
  (declare (type function function))
  (definition-source-for-emacs (sb-introspect:find-definition-source function)
                               :function
                               (or name (function-name function))))

(defimplementation describe-symbol-for-emacs (symbol)
  "Return a plist describing SYMBOL.
Return NIL if the symbol is unbound."
  (let ((result '()))
    (flet ((doc (kind)
             (or (documentation symbol kind) :not-documented))
           (maybe-push (property value)
             (when value
               (setf result (list* property value result)))))
      (maybe-push
       :variable (multiple-value-bind (kind recorded-p)
		     (sb-int:info :variable :kind symbol)
		   (declare (ignore kind))
		   (if (or (boundp symbol) recorded-p)
		       (doc 'variable))))
      (when (fboundp symbol)
	(maybe-push
	 (cond ((macro-function symbol)     :macro)
	       ((special-operator-p symbol) :special-operator)
	       ((typep (fdefinition symbol) 'generic-function)
                :generic-function)
	       (t :function))
	 (doc 'function)))
      (maybe-push
       :setf (if (or (sb-int:info :setf :inverse symbol)
		     (sb-int:info :setf :expander symbol))
		 (doc 'setf)))
      (maybe-push
       :type (if (sb-int:info :type :kind symbol)
		 (doc 'type)))
      result)))

(defimplementation describe-definition (symbol type)
  (case type
    (:variable
     (describe symbol))
    (:function
     (describe (symbol-function symbol)))
    (:setf
     (describe (or (sb-int:info :setf :inverse symbol)
                   (sb-int:info :setf :expander symbol))))
    (:class
     (describe (find-class symbol)))
    (:type
     (describe (sb-kernel:values-specifier-type symbol)))))
  
#+#.(swank-backend::sbcl-with-xref-p)
(progn
  (defmacro defxref (name &optional fn-name)
    `(defimplementation ,name (what)
       (sanitize-xrefs   
        (mapcar #'source-location-for-xref-data
                (,(find-symbol (symbol-name (if fn-name
                                                fn-name
                                                name))
                               "SB-INTROSPECT")
                  what)))))
  (defxref who-calls)
  (defxref who-binds)
  (defxref who-sets)
  (defxref who-references)
  (defxref who-macroexpands)
  #+#.(swank-backend:with-symbol 'who-specializes-directly 'sb-introspect)
  (defxref who-specializes who-specializes-directly))

(defun source-location-for-xref-data (xref-data)
  (destructuring-bind (name . defsrc) xref-data
    (list name (converting-errors-to-error-location
                 (definition-source-for-emacs defsrc 'function name)))))

(defimplementation list-callers (symbol)
  (let ((fn (fdefinition symbol)))
    (sanitize-xrefs
     (mapcar #'function-dspec (sb-introspect:find-function-callers fn)))))

(defimplementation list-callees (symbol)
  (let ((fn (fdefinition symbol)))
    (sanitize-xrefs
     (mapcar #'function-dspec (sb-introspect:find-function-callees fn)))))

(defun sanitize-xrefs (xrefs)
  (remove-duplicates
   (remove-if (lambda (f)
                (member f (ignored-xref-function-names)))
              (loop for entry in xrefs
                    for name = (car entry)
                    collect (if (and (consp name)
                                     (member (car name)
                                             '(sb-pcl::fast-method
                                               sb-pcl::slow-method
                                               sb-pcl::method)))
                                (cons (cons 'defmethod (cdr name))
                                      (cdr entry))
                                entry))
              :key #'car)
   :test (lambda (a b)
           (and (eq (first a) (first b))
                (equal (second a) (second b))))))

(defun ignored-xref-function-names ()
  #-#.(swank-backend::sbcl-with-new-stepper-p)
  '(nil sb-c::step-form sb-c::step-values)
  #+#.(swank-backend::sbcl-with-new-stepper-p)
  '(nil))

(defun function-dspec (fn)
  "Describe where the function FN was defined.
Return a list of the form (NAME LOCATION)."
  (let ((name (function-name fn)))
    (list name (converting-errors-to-error-location
                 (function-source-location fn name)))))

;;; macroexpansion

(defimplementation macroexpand-all (form)
  (let ((sb-walker:*walk-form-expand-macros-p* t))
    (sb-walker:walk-form form)))


;;; Debugging

;;; Notice that SB-EXT:*INVOKE-DEBUGGER-HOOK* is slightly stronger
;;; than just a hook into BREAK. In particular, it'll make
;;; (LET ((*DEBUGGER-HOOK* NIL)) ..error..) drop into SLDB rather
;;; than the native debugger. That should probably be considered a
;;; feature.

(defun make-invoke-debugger-hook (hook)
  (when hook
    #'(sb-int:named-lambda swank-invoke-debugger-hook
          (condition old-hook)
        (if *debugger-hook*
            nil         ; decline, *DEBUGGER-HOOK* will be tried next.
            (funcall hook condition old-hook)))))

(defun set-break-hook (hook)
  (setq sb-ext:*invoke-debugger-hook* (make-invoke-debugger-hook hook)))

(defun call-with-break-hook (hook continuation)
  (let ((sb-ext:*invoke-debugger-hook* (make-invoke-debugger-hook hook)))
    (funcall continuation)))

(defimplementation install-debugger-globally (function)
  (setq *debugger-hook* function)
  (set-break-hook function))

(defimplementation condition-extras (condition)
  (cond #+#.(swank-backend::sbcl-with-new-stepper-p)
        ((typep condition 'sb-impl::step-form-condition)
         `((:show-frame-source 0)))
        ((typep condition 'sb-int:reference-condition)
         (let ((refs (sb-int:reference-condition-references condition)))
           (if refs
               `((:references ,(externalize-reference refs))))))))

(defun externalize-reference (ref)
  (etypecase ref
    (null nil)
    (cons (cons (externalize-reference (car ref))
                (externalize-reference (cdr ref))))
    ((or string number) ref)
    (symbol 
     (cond ((eq (symbol-package ref) (symbol-package :test))
            ref)
           (t (symbol-name ref))))))

(defvar *sldb-stack-top*)

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (declare (type function debugger-loop-fn))
  (let* ((*sldb-stack-top* (if *debug-swank-backend*
                               (sb-di:top-frame)
                               (or sb-debug:*stack-top-hint*
                                   (sb-di:top-frame))))
         (sb-debug:*stack-top-hint* nil))
    (handler-bind ((sb-di:debug-condition
		    (lambda (condition)
                      (signal (make-condition
                               'sldb-condition
                               :original-condition condition)))))
      (funcall debugger-loop-fn))))

#+#.(swank-backend::sbcl-with-new-stepper-p)
(progn
  (defimplementation activate-stepping (frame)
    (declare (ignore frame))
    (sb-impl::enable-stepping))
  (defimplementation sldb-stepper-condition-p (condition)
    (typep condition 'sb-ext:step-form-condition))
  (defimplementation sldb-step-into ()
    (invoke-restart 'sb-ext:step-into))
  (defimplementation sldb-step-next ()
    (invoke-restart 'sb-ext:step-next))
  (defimplementation sldb-step-out ()
    (invoke-restart 'sb-ext:step-out)))

(defimplementation call-with-debugger-hook (hook fun)
  (let ((*debugger-hook* hook)
        #+#.(swank-backend::sbcl-with-new-stepper-p)
        (sb-ext:*stepper-hook*
         (lambda (condition)
           (typecase condition
             (sb-ext:step-form-condition
              (let ((sb-debug:*stack-top-hint* (sb-di::find-stepped-frame)))
                (sb-impl::invoke-debugger condition)))))))
    (handler-bind (#+#.(swank-backend::sbcl-with-new-stepper-p)
                   (sb-ext:step-condition #'sb-impl::invoke-stepper))
      (call-with-break-hook hook fun))))

(defun nth-frame (index)
  (do ((frame *sldb-stack-top* (sb-di:frame-down frame))
       (i index (1- i)))
      ((zerop i) frame)))

(defimplementation compute-backtrace (start end)
  "Return a list of frames starting with frame number START and
continuing to frame number END or, if END is nil, the last frame on the
stack."
  (let ((end (or end most-positive-fixnum)))
    (loop for f = (nth-frame start) then (sb-di:frame-down f)
	  for i from start below end
	  while f collect f)))

(defimplementation print-frame (frame stream)
  (sb-debug::print-frame-call frame stream))

(defimplementation frame-restartable-p (frame)
  #+#.(swank-backend::sbcl-with-restart-frame)
  (not (null (sb-debug:frame-has-debug-tag-p frame))))

(defimplementation frame-call (frame-number)
  (multiple-value-bind (name args)
      (sb-debug::frame-call (nth-frame frame-number))
    (with-output-to-string (stream)
      (pprint-logical-block (stream nil :prefix "(" :suffix ")")
        (let ((*print-length* nil)
              (*print-level* nil))
          (prin1 (sb-debug::ensure-printable-object name) stream))
        (let ((args (sb-debug::ensure-printable-object args)))
          (if (listp args)
              (format stream "~{ ~_~S~}" args)
              (format stream " ~S" args)))))))

;;;; Code-location -> source-location translation

;;; If debug-block info is avaibale, we determine the file position of
;;; the source-path for a code-location.  If the code was compiled
;;; with C-c C-c, we have to search the position in the source string.
;;; If there's no debug-block info, we return the (less precise)
;;; source-location of the corresponding function.

(defun code-location-source-location (code-location)
  (let* ((dsource (sb-di:code-location-debug-source code-location))
         (plist (sb-c::debug-source-plist dsource)))
    (if (getf plist :emacs-buffer)
        (emacs-buffer-source-location code-location plist)
        #+#.(swank-backend:with-symbol 'debug-source-from 'sb-di)
        (ecase (sb-di:debug-source-from dsource)
          (:file (file-source-location code-location))
          (:lisp (lisp-source-location code-location)))
        #-#.(swank-backend:with-symbol 'debug-source-from 'sb-di)
        (if (sb-di:debug-source-namestring dsource)
            (file-source-location code-location)
            (lisp-source-location code-location)))))

;;; FIXME: The naming policy of source-location functions is a bit
;;; fuzzy: we have FUNCTION-SOURCE-LOCATION which returns the
;;; source-location for a function, and we also have FILE-SOURCE-LOCATION &co
;;; which returns the source location for a _code-location_.
;;;
;;; Maybe these should be named code-location-file-source-location,
;;; etc, turned into generic functions, or something. In the very
;;; least the names should indicate the main entry point vs. helper
;;; status.

(defun file-source-location (code-location)
  (if (code-location-has-debug-block-info-p code-location)
      (source-file-source-location code-location)
      (fallback-source-location code-location)))

(defun fallback-source-location (code-location)
  (let ((fun (code-location-debug-fun-fun code-location)))
    (cond (fun (function-source-location fun))
          (t (error "Cannot find source location for: ~A " code-location)))))

(defun lisp-source-location (code-location)
  (let ((source (prin1-to-string
                 (sb-debug::code-location-source-form code-location 100)))
        (condition (swank-value '*swank-debugger-condition*)))
    (if (typep condition 'sb-impl::step-form-condition)
        (and (search "SB-IMPL::WITH-STEPPING-ENABLED" source
                     :test #'char-equal)
             (search "SB-IMPL::STEP-FINISHED" source :test #'char-equal))
        ;; The initial form is utterly uninteresting -- and almost
        ;; certainly right there in the REPL.
        (make-error-location "Stepping...")
        (make-location `(:source-form ,source) '(:position 1)))))

(defun emacs-buffer-source-location (code-location plist)
  (if (code-location-has-debug-block-info-p code-location)
      (destructuring-bind (&key emacs-buffer emacs-position emacs-string
                                &allow-other-keys)
          plist
        (let* ((pos (string-source-position code-location emacs-string))
               (snipped (read-snippet-from-string emacs-string pos)))
          (make-location `(:buffer ,emacs-buffer)
                         `(:offset ,emacs-position ,pos)
                         `(:snippet ,snipped))))
      (fallback-source-location code-location)))

(defun source-file-source-location (code-location)
  (let* ((code-date (code-location-debug-source-created code-location))
         (filename (code-location-debug-source-name code-location))
         (*readtable* (guess-readtable-for-filename filename))
         (source-code (get-source-code filename code-date)))
    (with-debootstrapping
      (with-input-from-string (s source-code)
        (let* ((pos (stream-source-position code-location s))
               (snippet (read-snippet s pos)))
          (make-location `(:file ,filename)
                         `(:position ,pos)
                         `(:snippet ,snippet)))))))

(defun code-location-debug-source-name (code-location)
  (namestring (truename (#+#.(swank-backend:with-symbol
                              'debug-source-name 'sb-di)
                             sb-c::debug-source-name
                             #-#.(swank-backend:with-symbol
                                  'debug-source-name 'sb-di)
                             sb-c::debug-source-namestring
                         (sb-di::code-location-debug-source code-location)))))

(defun code-location-debug-source-created (code-location)
  (sb-c::debug-source-created
   (sb-di::code-location-debug-source code-location)))

(defun code-location-debug-fun-fun (code-location)
  (sb-di:debug-fun-fun (sb-di:code-location-debug-fun code-location)))

(defun code-location-has-debug-block-info-p (code-location)
  (handler-case
      (progn (sb-di:code-location-debug-block code-location)
             t)
    (sb-di:no-debug-blocks  () nil)))

(defun stream-source-position (code-location stream)
  (let* ((cloc (sb-debug::maybe-block-start-location code-location))
	 (tlf-number (sb-di::code-location-toplevel-form-offset cloc))
	 (form-number (sb-di::code-location-form-number cloc)))
    (multiple-value-bind (tlf pos-map) (read-source-form tlf-number stream)
      (let* ((path-table (sb-di::form-number-translations tlf 0))
             (path (cond ((<= (length path-table) form-number)
                          (warn "inconsistent form-number-translations")
                          (list 0))
                         (t
                          (reverse (cdr (aref path-table form-number)))))))
        (source-path-source-position path tlf pos-map)))))

(defun string-source-position (code-location string)
  (with-input-from-string (s string)
    (stream-source-position code-location s)))

;;; source-path-file-position and friends are in swank-source-path-parser

(defimplementation frame-source-location (index)
  (converting-errors-to-error-location
    (code-location-source-location
     (sb-di:frame-code-location (nth-frame index)))))

(defun frame-debug-vars (frame)
  "Return a vector of debug-variables in frame."
  (sb-di::debug-fun-debug-vars (sb-di:frame-debug-fun frame)))

(defun debug-var-value (var frame location)
  (ecase (sb-di:debug-var-validity var location)
    (:valid (sb-di:debug-var-value var frame))
    ((:invalid :unknown) ':<not-available>)))

(defun debug-var-info (var)
  ;; Introduced by SBCL 1.0.49.76.
  (let ((s (find-symbol "DEBUG-VAR-INFO" :sb-di)))
    (when (and s (fboundp s))
      (funcall s var))))

(defimplementation frame-locals (index)
  (let* ((frame (nth-frame index))
	 (loc (sb-di:frame-code-location frame))
	 (vars (frame-debug-vars frame))
         ;; Since SBCL 1.0.49.76 PREPROCESS-FOR-EVAL understands SB-DEBUG::MORE
         ;; specially.
         (more-name (or (find-symbol "MORE" :sb-debug) 'more))
         (more-context nil)
         (more-count nil)
         (more-id 0))
    (when vars
      (let ((locals
              (loop for v across vars
                    do (when (eq (sb-di:debug-var-symbol v) more-name)
                         (incf more-id))
                       (case (debug-var-info v)
                         (:more-context
                          (setf more-context (debug-var-value v frame loc)))
                         (:more-count
                          (setf more-count (debug-var-value v frame loc))))
                    collect
                       (list :name (sb-di:debug-var-symbol v)
                             :id (sb-di:debug-var-id v)
                             :value (debug-var-value v frame loc)))))
        (when (and more-context more-count)
          (setf locals (append locals
                               (list
                                (list :name more-name
                                      :id more-id
                                      :value (multiple-value-list
                                              (sb-c:%more-arg-values 
                                               more-context
                                               0 more-count)))))))
        locals))))

(defimplementation frame-var-value (frame var)
  (let* ((frame (nth-frame frame))
         (vars (frame-debug-vars frame))
         (loc (sb-di:frame-code-location frame))
         (dvar (if (= var (length vars))
                   ;; If VAR is out of bounds, it must be the fake var
                   ;; we made up for &MORE.
                   (let* ((context-var (find :more-context vars 
                                             :key #'debug-var-info))
                          (more-context (debug-var-value context-var frame 
                                                         loc))
                          (count-var (find :more-count vars 
                                           :key #'debug-var-info))
                          (more-count (debug-var-value count-var frame loc)))
                     (return-from frame-var-value
                       (multiple-value-list (sb-c:%more-arg-values
                                             more-context
                                             0 more-count))))
                   (aref vars var))))
    (debug-var-value dvar frame loc)))

(defimplementation frame-catch-tags (index)
  (mapcar #'car (sb-di:frame-catches (nth-frame index))))

(defimplementation eval-in-frame (form index)
  (let ((frame (nth-frame index)))
    (funcall (the function
               (sb-di:preprocess-for-eval form
                                          (sb-di:frame-code-location frame)))
             frame)))

#+#.(swank-backend::sbcl-with-restart-frame)
(progn
  (defimplementation return-from-frame (index form)
    (let* ((frame (nth-frame index)))
      (cond ((sb-debug:frame-has-debug-tag-p frame)
             (let ((values (multiple-value-list (eval-in-frame form index))))
               (sb-debug:unwind-to-frame-and-call frame
                                                   (lambda ()
                                                     (values-list values)))))
            (t (format nil "Cannot return from frame: ~S" frame)))))

  (defimplementation restart-frame (index)
    (let ((frame (nth-frame index)))
      (when (sb-debug:frame-has-debug-tag-p frame)
        (multiple-value-bind (fname args) (sb-debug::frame-call frame)
          (multiple-value-bind (fun arglist)
              (if (and (sb-int:legal-fun-name-p fname) (fboundp fname))
                  (values (fdefinition fname) args)
                  (values (sb-di:debug-fun-fun (sb-di:frame-debug-fun frame))
                          (sb-debug::frame-args-as-list frame)))
            (when (functionp fun)
              (sb-debug:unwind-to-frame-and-call 
               frame
               (lambda ()
                 ;; Ensure TCO.
                 (declare (optimize (debug 0)))
                 (apply fun arglist)))))))
      (format nil "Cannot restart frame: ~S" frame))))

;; FIXME: this implementation doesn't unwind the stack before
;; re-invoking the function, but it's better than no implementation at
;; all.
#-#.(swank-backend::sbcl-with-restart-frame)
(progn
  (defun sb-debug-catch-tag-p (tag)
    (and (symbolp tag)
         (not (symbol-package tag))
         (string= tag :sb-debug-catch-tag)))
  
  (defimplementation return-from-frame (index form)
    (let* ((frame (nth-frame index))
           (probe (assoc-if #'sb-debug-catch-tag-p
                            (sb-di::frame-catches frame))))
      (cond (probe (throw (car probe) (eval-in-frame form index)))
            (t (format nil "Cannot return from frame: ~S" frame)))))
  
  (defimplementation restart-frame (index)
    (let ((frame (nth-frame index)))
      (return-from-frame index (sb-debug::frame-call-as-list frame)))))

;;;;; reference-conditions

(defimplementation format-sldb-condition (condition)
  (let ((sb-int:*print-condition-references* nil))
    (princ-to-string condition)))


;;;; Profiling

(defimplementation profile (fname)
  (when fname (eval `(sb-profile:profile ,fname))))

(defimplementation unprofile (fname)
  (when fname (eval `(sb-profile:unprofile ,fname))))

(defimplementation unprofile-all ()
  (sb-profile:unprofile)
  "All functions unprofiled.")

(defimplementation profile-report ()
  (sb-profile:report))

(defimplementation profile-reset ()
  (sb-profile:reset)
  "Reset profiling counters.")

(defimplementation profiled-functions ()
  (sb-profile:profile))

(defimplementation profile-package (package callers methods)
  (declare (ignore callers methods))
  (eval `(sb-profile:profile ,(package-name (find-package package)))))


;;;; Inspector

(defmethod emacs-inspect ((o t))
  (cond ((sb-di::indirect-value-cell-p o)
         (label-value-line* (:value (sb-kernel:value-cell-ref o))))
	(t
	 (multiple-value-bind (text label parts) (sb-impl::inspected-parts o)
           (list* (string-right-trim '(#\Newline) text)
                  '(:newline)
                  (if label
                      (loop for (l . v) in parts
                            append (label-value-line l v))
                      (loop for value in parts
                            for i from 0
                            append (label-value-line i value))))))))

(defmethod emacs-inspect ((o function))
  (let ((header (sb-kernel:widetag-of o)))
    (cond ((= header sb-vm:simple-fun-header-widetag)
                   (label-value-line*
                    (:name (sb-kernel:%simple-fun-name o))
                    (:arglist (sb-kernel:%simple-fun-arglist o))
                    (:self (sb-kernel:%simple-fun-self o))
                    (:next (sb-kernel:%simple-fun-next o))
                    (:type (sb-kernel:%simple-fun-type o))
                    (:code (sb-kernel:fun-code-header o))))
	  ((= header sb-vm:closure-header-widetag)
                   (append
                    (label-value-line :function (sb-kernel:%closure-fun o))
                    `("Closed over values:" (:newline))
                    (loop for i below (1- (sb-kernel:get-closure-length o))
                          append (label-value-line
                                  i (sb-kernel:%closure-index-ref o i)))))
	  (t (call-next-method o)))))

(defmethod emacs-inspect ((o sb-kernel:code-component))
          (append
           (label-value-line*
            (:code-size (sb-kernel:%code-code-size o))
            (:entry-points (sb-kernel:%code-entry-points o))
            (:debug-info (sb-kernel:%code-debug-info o))
            (:trace-table-offset (sb-kernel:code-header-ref
                                  o sb-vm:code-trace-table-offset-slot)))
           `("Constants:" (:newline))
           (loop for i from sb-vm:code-constants-offset
                 below (sb-kernel:get-header-data o)
                 append (label-value-line i (sb-kernel:code-header-ref o i)))
           `("Code:" (:newline)
             , (with-output-to-string (s)
                 (cond ((sb-kernel:%code-debug-info o)
                        (sb-disassem:disassemble-code-component o :stream s))
                       (t
                        (sb-disassem:disassemble-memory
                         (sb-disassem::align
                          (+ (logandc2 (sb-kernel:get-lisp-obj-address o)
                                       sb-vm:lowtag-mask)
                             (* sb-vm:code-constants-offset
                                sb-vm:n-word-bytes))
                          (ash 1 sb-vm:n-lowtag-bits))
                         (ash (sb-kernel:%code-code-size o) sb-vm:word-shift)
                         :stream s)))))))

(defmethod emacs-inspect ((o sb-ext:weak-pointer))
          (label-value-line*
           (:value (sb-ext:weak-pointer-value o))))

(defmethod emacs-inspect ((o sb-kernel:fdefn))
          (label-value-line*
           (:name (sb-kernel:fdefn-name o))
           (:function (sb-kernel:fdefn-fun o))))

(defmethod emacs-inspect :around ((o generic-function))
            (append
             (call-next-method)
             (label-value-line*
              (:pretty-arglist (sb-pcl::generic-function-pretty-arglist o))
              (:initial-methods (sb-pcl::generic-function-initial-methods o))
              )))


;;;; Multiprocessing

#+(and sb-thread
       #.(swank-backend:with-symbol "THREAD-NAME" "SB-THREAD"))
(progn
  (defvar *thread-id-counter* 0)

  (defvar *thread-id-counter-lock*
    (sb-thread:make-mutex :name "thread id counter lock"))

  (defun next-thread-id ()
    (sb-thread:with-mutex (*thread-id-counter-lock*)
      (incf *thread-id-counter*)))

  (defparameter *thread-id-map* (make-hash-table))

  ;; This should be a thread -> id map but as weak keys are not
  ;; supported it is id -> map instead.
  (defvar *thread-id-map-lock*
    (sb-thread:make-mutex :name "thread id map lock"))

  (defimplementation spawn (fn &key name)
    (sb-thread:make-thread fn :name name))

  (defimplementation thread-id (thread)
    (block thread-id
      (sb-thread:with-mutex (*thread-id-map-lock*)
        (loop for id being the hash-key in *thread-id-map*
              using (hash-value thread-pointer)
              do
              (let ((maybe-thread (sb-ext:weak-pointer-value thread-pointer)))
                (cond ((null maybe-thread)
                       ;; the value is gc'd, remove it manually
                       (remhash id *thread-id-map*))
                      ((eq thread maybe-thread)
                       (return-from thread-id id)))))
        ;; lazy numbering
        (let ((id (next-thread-id)))
          (setf (gethash id *thread-id-map*) (sb-ext:make-weak-pointer thread))
          id))))

  (defimplementation find-thread (id)
    (sb-thread:with-mutex (*thread-id-map-lock*)
      (let ((thread-pointer (gethash id *thread-id-map*)))
        (if thread-pointer
            (let ((maybe-thread (sb-ext:weak-pointer-value thread-pointer)))
              (if maybe-thread
                  maybe-thread
                  ;; the value is gc'd, remove it manually
                  (progn
                    (remhash id *thread-id-map*)
                    nil)))
            nil))))

  (defimplementation thread-name (thread)
    ;; sometimes the name is not a string (e.g. NIL)
    (princ-to-string (sb-thread:thread-name thread)))

  (defimplementation thread-status (thread)
    (if (sb-thread:thread-alive-p thread)
        "Running"
        "Stopped"))
  
  (defimplementation make-lock (&key name)
    (sb-thread:make-mutex :name name))

  (defimplementation call-with-lock-held (lock function)
    (declare (type function function))
    (sb-thread:with-recursive-lock (lock) (funcall function)))

  (defimplementation current-thread ()
    sb-thread:*current-thread*)

  (defimplementation all-threads ()
    (sb-thread:list-all-threads))

  (defimplementation interrupt-thread (thread fn)
    (sb-thread:interrupt-thread thread fn))

  (defimplementation kill-thread (thread)
    (sb-thread:terminate-thread thread))

  (defimplementation thread-alive-p (thread)
    (sb-thread:thread-alive-p thread))

  (defvar *mailbox-lock* (sb-thread:make-mutex :name "mailbox lock"))
  (defvar *mailboxes* (list))
  (declaim (type list *mailboxes*))

  (defstruct (mailbox (:conc-name mailbox.))
    thread
    (mutex (sb-thread:make-mutex))
    (waitqueue  (sb-thread:make-waitqueue))
    (queue '() :type list))

  (defun mailbox (thread)
    "Return THREAD's mailbox."
    (sb-thread:with-mutex (*mailbox-lock*)
      (or (find thread *mailboxes* :key #'mailbox.thread)
          (let ((mb (make-mailbox :thread thread)))
            (push mb *mailboxes*)
            mb))))

  (defimplementation send (thread message)
    (let* ((mbox (mailbox thread))
           (mutex (mailbox.mutex mbox)))
      (sb-thread:with-mutex (mutex)
        (setf (mailbox.queue mbox)
              (nconc (mailbox.queue mbox) (list message)))
        (sb-thread:condition-broadcast (mailbox.waitqueue mbox)))))
  #-sb-lutex
  (defun condition-timed-wait (waitqueue mutex timeout)
    (handler-case 
        (let ((*break-on-signals* nil))
          (sb-sys:with-deadline (:seconds timeout :override t)
            (sb-thread:condition-wait waitqueue mutex) t))
      (sb-ext:timeout ()
        nil)))

  ;; FIXME: with-timeout doesn't work properly on Darwin
  #+sb-lutex
  (defun condition-timed-wait (waitqueue mutex timeout)
    (declare (ignore timeout))
    (sb-thread:condition-wait waitqueue mutex))
  
  (defimplementation receive-if (test &optional timeout)
    (let* ((mbox (mailbox (current-thread)))
           (mutex (mailbox.mutex mbox))
           (waitq (mailbox.waitqueue mbox)))
      (assert (or (not timeout) (eq timeout t)))
      (loop
       (check-slime-interrupts)
       (sb-thread:with-mutex (mutex)
         (let* ((q (mailbox.queue mbox))
                (tail (member-if test q)))
           (when tail 
             (setf (mailbox.queue mbox) (nconc (ldiff q tail) (cdr tail)))
             (return (car tail))))
         (when (eq timeout t) (return (values nil t)))
         (condition-timed-wait waitq mutex 0.2)))))

  (let ((alist '())
        (mutex (sb-thread:make-mutex :name "register-thread")))

    (defimplementation register-thread (name thread)
      (declare (type symbol name))
      (sb-thread:with-mutex (mutex)
        (etypecase thread
          (null 
           (setf alist (delete name alist :key #'car)))
          (sb-thread:thread
           (let ((probe (assoc name alist)))
             (cond (probe (setf (cdr probe) thread))
                   (t (setf alist (acons name thread alist))))))))
      nil)

    (defimplementation find-registered (name)
      (sb-thread:with-mutex (mutex) 
        (cdr (assoc name alist)))))

  ;; Workaround for deadlocks between the world-lock and auto-flush-thread
  ;; buffer write lock.
  ;;
  ;; Another alternative would be to grab the world-lock here, but that's less
  ;; future-proof, and could introduce other lock-ordering issues in the
  ;; future.
  ;;
  ;; In an ideal world we would just have an :AROUND method on
  ;; SLIME-OUTPUT-STREAM, and be done, but that class doesn't exist when this
  ;; file is loaded -- so first we need a dummy definition that will be
  ;; overridden by swank-gray.lisp.
  (defclass slime-output-stream (fundamental-character-output-stream)
    ())
  (defmethod stream-force-output :around ((stream slime-output-stream))
    (handler-case
        (sb-sys:with-deadline (:seconds 0.1)
          (call-next-method))
      (sb-sys:deadline-timeout ()
        nil)))

  )

(defimplementation quit-lisp ()
  #+sb-thread
  (dolist (thread (remove (current-thread) (all-threads)))
    (ignore-errors (sb-thread:terminate-thread thread)))
  (sb-ext:quit))



;;Trace implementations
;;In SBCL, we have:
;; (trace <name>)
;; (trace :methods '<name>) ;to trace all methods of the gf <name>
;; (trace (method <name> <qualifier>? (<specializer>+)))
;; <name> can be a normal name or a (setf name)

(defun toggle-trace-aux (fspec &rest args)
  (cond ((member fspec (eval '(trace)) :test #'equal)
         (eval `(untrace ,fspec))
         (format nil "~S is now untraced." fspec))
        (t
         (eval `(trace ,@(if args `(:encapsulate nil) (list)) ,fspec ,@args))
         (format nil "~S is now traced." fspec))))

(defun process-fspec (fspec)
  (cond ((consp fspec)
         (ecase (first fspec)
           ((:defun :defgeneric) (second fspec))
           ((:defmethod) `(method ,@(rest fspec)))
           ((:labels) `(labels ,(process-fspec (second fspec)) ,(third fspec)))
           ((:flet) `(flet ,(process-fspec (second fspec)) ,(third fspec)))))
        (t
         fspec)))

(defimplementation toggle-trace (spec)
  (ecase (car spec)
    ((setf)
     (toggle-trace-aux spec))
    ((:defmethod)
     (toggle-trace-aux `(sb-pcl::fast-method ,@(rest (process-fspec spec)))))
    ((:defgeneric)
     (toggle-trace-aux (second spec) :methods t))
    ((:call)
     (destructuring-bind (caller callee) (cdr spec)
       (toggle-trace-aux callee :wherein (list (process-fspec caller)))))))

;;; Weak datastructures

(defimplementation make-weak-key-hash-table (&rest args)  
  #+#.(swank-backend::sbcl-with-weak-hash-tables)
  (apply #'make-hash-table :weakness :key args)
  #-#.(swank-backend::sbcl-with-weak-hash-tables)
  (apply #'make-hash-table args))

(defimplementation make-weak-value-hash-table (&rest args)
  #+#.(swank-backend::sbcl-with-weak-hash-tables)
  (apply #'make-hash-table :weakness :value args)
  #-#.(swank-backend::sbcl-with-weak-hash-tables)
  (apply #'make-hash-table args))

(defimplementation hash-table-weakness (hashtable)
  #+#.(swank-backend::sbcl-with-weak-hash-tables)
  (sb-ext:hash-table-weakness hashtable))

#-win32
(defimplementation save-image (filename &optional restart-function)
  (flet ((restart-sbcl ()
           (sb-debug::enable-debugger)
           (setf sb-impl::*descriptor-handlers* nil)
           (funcall restart-function)))
    (let ((pid (sb-posix:fork)))
      (cond ((= pid 0)
             (sb-debug::disable-debugger)
             (apply #'sb-ext:save-lisp-and-die filename
                    (when restart-function
                      (list :toplevel #'restart-sbcl))))
            (t
             (multiple-value-bind (rpid status) (sb-posix:waitpid pid 0)
               (assert (= pid rpid))
               (assert (and (sb-posix:wifexited status)
                            (zerop (sb-posix:wexitstatus status))))))))))

#+unix
(progn
  (sb-alien:define-alien-routine ("execv" sys-execv) sb-alien:int
    (program sb-alien:c-string)
    (argv (* sb-alien:c-string)))

  (defun execv (program args)
    "Replace current executable with another one."
    (let ((a-args (sb-alien:make-alien sb-alien:c-string
                                       (+ 1 (length args)))))
      (unwind-protect
           (progn
             (loop for index from 0 by 1
                   and item in (append args '(nil))
                   do (setf (sb-alien:deref a-args index)
                            item))
             (when (minusp
                    (sys-execv program a-args))
               (error "execv(3) returned.")))
        (sb-alien:free-alien a-args))))

  (defun runtime-pathname ()
    #+#.(swank-backend:with-symbol
            '*runtime-pathname* 'sb-ext)
    sb-ext:*runtime-pathname*
    #-#.(swank-backend:with-symbol
            '*runtime-pathname* 'sb-ext)
    (car sb-ext:*posix-argv*))

  (defimplementation exec-image (image-file args)
    (loop with fd-arg =
          (loop for arg in args
                and key = "" then arg
                when (string-equal key "--swank-fd")
                return (parse-integer arg))
          for my-fd from 3 to 1024
          when (/= my-fd fd-arg)
          do (ignore-errors (sb-posix:fcntl my-fd sb-posix:f-setfd 1)))
    (let* ((self-string (pathname-to-filename (runtime-pathname))))
      (execv
       self-string
       (apply 'list self-string "--core" image-file args)))))

(defimplementation make-fd-stream (fd external-format)
  (sb-sys:make-fd-stream fd :input t :output t
                         :element-type 'character
                         :buffering :full
                         :dual-channel-p t                         
                         :external-format external-format))

(defimplementation call-with-io-timeout (function &key seconds)
  (handler-case
      (sb-sys:with-deadline (:seconds seconds)
        (funcall function))
    (sb-sys:deadline-timeout ()
      nil)))

#-win32
(defimplementation background-save-image (filename &key restart-function
                                                   completion-function)
  (flet ((restart-sbcl ()
           (sb-debug::enable-debugger)
           (setf sb-impl::*descriptor-handlers* nil)
           (funcall restart-function)))
    (multiple-value-bind (pipe-in pipe-out) (sb-posix:pipe)
      (let ((pid (sb-posix:fork)))
        (cond ((= pid 0)
               (sb-posix:close pipe-in)
               (sb-debug::disable-debugger)
               (apply #'sb-ext:save-lisp-and-die filename
                      (when restart-function
                        (list :toplevel #'restart-sbcl))))
              (t
               (sb-posix:close pipe-out)
               (sb-sys:add-fd-handler
                pipe-in :input
                (lambda (fd)
                  (sb-sys:invalidate-descriptor fd)
                  (sb-posix:close fd)
                  (multiple-value-bind (rpid status) (sb-posix:waitpid pid 0)
                    (assert (= pid rpid))
                    (assert (sb-posix:wifexited status))
                    (funcall completion-function
                             (zerop (sb-posix:wexitstatus status))))))))))))

(defun deinit-log-output ()
  ;; Can't hang on to an fd-stream from a previous session.
  (setf (symbol-value (find-symbol "*LOG-OUTPUT*" 'swank))
        nil))

(pushnew 'deinit-log-output sb-ext:*save-hooks*)
