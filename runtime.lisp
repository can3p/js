(in-package :js)

;;
(defgeneric set-default (hash val) ;;todo: put it as a slot writer
  (:method (hash val) (declare (ignore hash)) val))

(defgeneric prop (hash key &optional default)
  (:method (hash key &optional default)
    (declare (ignore hash key default)) :undefined))

(defgeneric (setf prop) (val hash key)
  (:method (val hash key) (declare (ignore hash key)) val))

(defgeneric sub (hash key)
  (:method (hash key) (prop hash key)))

(defgeneric (setf sub) (val hash key)
  (:method (val hash key) (setf (prop hash key) val)))

(defgeneric placeholder-class (func)
  (:method (func) (declare (ignore func)) 'native-hash))

(defgeneric value (obj)
  (:method (obj) obj))

;;
(defclass native-hash ()
  ((default-value :accessor value :initform nil :initarg :value)
   (dict :accessor dict :initform (make-hash-table :test 'equal))
   (sealed :accessor sealed :initform nil :initarg :sealed)
   (prototype :accessor prototype :initform nil :initarg :prototype)))

(defmethod set-default ((hash native-hash) val)
  (setf (value hash) val))

(defun add-sealed-property (hash key proc)
  (flet ((ensure-sealed-table (hash)
	   (or (sealed hash)
	       (setf (sealed hash) (make-hash-table :test 'equal)))))
    (let ((sealed-table (ensure-sealed-table hash)))
      (setf (gethash key sealed-table) proc))))

(defmethod prop ((hash native-hash) key &optional (default :undefined))
  (let* ((sealed (sealed hash))
	 (action (and sealed (gethash key sealed))))
    (if action (funcall action hash)
	(multiple-value-bind (val exists)
	    (gethash key (dict hash))
	  (if exists val
	      (or (and (prototype hash)
		       (prop (prototype hash) key default))
		  default))))))

(defmethod (setf prop) (val (hash native-hash) key)
  (setf (gethash key (dict hash)) val))

;;
(defclass global-object (native-hash)
  ())

(defmethod (setf prop) (val (hash global-object) key)
  (set (if (stringp key) (intern (string-upcase key) :js-user) key) val);;todo:
  (call-next-method val hash key))

(defmethod set-default ((hash global-object) val)
  val)

(defparameter *global* (make-instance 'global-object))
(defparameter js-user::this *global*)

;;
(defclass native-function (native-hash)
  ((name :accessor name :initarg :name)
   (proc :accessor proc :initarg :proc)
   (env :accessor env :initarg :env)))

(defmethod initialize-instance :after ((f native-function) &rest args)
  (declare (ignore args))
  (setf (prop f "prototype") (make-instance 'native-hash)))

(defparameter function.prototype
  (make-instance 'native-function
		 :proc (lambda (&rest args) (declare (ignore args)) :undefined)))

(defun new-function (&rest args) ;;due to parser error it is
				 ;;impossible to use anonymous
				 ;;function as a atandalone expression
				 ;;so we propagate it via identity
				 ;;lambda
  (eval
   (process-ast
    (parse-js-string
     (if args
	 (format nil "(function(val) {return val;})(function (~{~a~^, ~}) {~A});"
		 (butlast args) (car (last args)))
	 "(function(val) {return val;})(function () {});")))))

(defmethod set-default ((func native-function) val)
  (setf (prototype func) function.prototype)
  (setf (proc func) (proc val))
  (setf (name func) nil))

(defparameter function.ctor
  (js-function ()
    (let ((func (apply #'new-function (arguments-as-list (!arguments)))))
      (set-default js-user::this func)
      func)))

(setf (prop function.prototype "constructor") function.ctor)

(defmethod placeholder-class ((func (eql function.ctor))) 'native-function)

(setf (prop function.ctor "prototype") function.prototype)
(setf (prop *global* "Function") function.ctor)

;;
(defclass arguments (native-hash)
  ((vlen :initarg :vlen :reader vlen)
   (length :initarg :length :reader arg-length)
   (get-arr :initarg :get-arr :reader get-arr)
   (set-arr :initarg :set-arr :reader set-arr)))

(defmethod sub ((args arguments) key)
  (if (and (integerp key) (>= key 0))
      (if (< key (vlen args)) (funcall (aref (get-arr args) key) key)
	  (funcall (aref (get-arr args) (vlen args)) key))
      (call-next-method args key)))

(defmethod (setf sub) (val (args arguments) key)
  (if (and (integerp key) (>= key 0))
      (if (< key (vlen args)) (funcall (aref (set-arr args) key) key val)
	  (funcall (aref (set-arr args) (vlen args)) key val))
      (call-next-method val args key)))

(defun arguments-as-list (args)
  (loop for i from 0 below (arg-length args)
     collecting (sub args i)))


;;; todo: array differs from string (according to spidermonkey) in
;;; respect of calling constructor without operator new. string
;;; returns a new basic string instead of an object, but arrays behave
;;; like there is no difference whether the ctor is invoked with or
;;; without new. our current implementation implements array to behave
;;; like string. recheck the spec
;;
(defclass array-object (native-hash)
  ())

(defmethod prop ((arr array-object) key &optional (default :undefined))
  (if (integerp key) ;;todo: safe conversion to integer and boundary check
      (aref (value arr) key)
      (call-next-method arr key default)))

(defmethod (setf prop) (val (arr array-object) key)
  (if (integerp key) ;;todo: ... as above ...
      (setf (aref (value arr) key) val)
      (call-next-method val arr key)))

(defparameter array.ctor
  (js-function ()
    (let* ((len (js::arg-length (!arguments)))
	   (arr (make-array len
			    :fill-pointer len
			    :initial-contents
			    (arguments-as-list (!arguments)))))
      (set-default js-user::this arr)
      arr)))

(defmethod placeholder-class ((func (eql array.ctor))) 'array-object)

(defparameter array.prototype (js-new js::array.ctor ()))

(setf (prop array.ctor "prototype") array.prototype)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (shadow 'Array 'js-user)) ;;todo: ...

(setf (prop *global* "Array") array.ctor)

;;
(defparameter string.ctor
  (js-function (obj)
    (let ((str (if (stringp obj) obj (format nil "~A" obj))))
      (set-default js-user::this str)
      (the string str))))

(defparameter string.prototype
  (js-new js::string.ctor '("")))

(setf (prop string.ctor "prototype") string.prototype)
(setf (prop *global* "String") string.ctor)

(defmethod prop ((str string) key &optional (default :undefined))
  (let* ((sealed (sealed string.prototype))
	 (action (gethash key sealed)))
    (if action
	(funcall action str)
	(prop string.prototype key default))))

;;
(defparameter number.ctor ;;todo: set-default (same as string)
  (js-function (n)
    (cond ((numberp n) n)
	  ((stringp n)
	   (with-input-from-string (s n)
	     (js-funcall number.ctor (read s))))
	  (t :NaN))))
