From MetaCoq.Utils Require Import utils.
Require Import List String.
Import ListNotations.
Local Open Scope string_scope.
From Malfunction Require Import Mcase.
From MetaCoq Require Import ReflectEq EWcbvEvalNamed bytestring MCList.

From Malfunction Require Import Compile SemanticsSpec utils_array.

From Equations Require Import Equations.

Definition lookup {A} (E : list (Kernames.ident * A)) (x : string) :=
  match find (fun '(s, _) => String.eqb x s) E with
  | Some (_, v) => Some v
  | None => None
  end.

Fixpoint compile_value {H : Heap} (Σ : EAst.global_declarations) (s : EWcbvEvalNamed.value) : SemanticsSpec.value :=
  match s with
  | vClos na b env => Func ((fun x => match lookup (map (fun '(x,v) => (x, compile_value Σ v)) env) x with Some v => v | None => fail "notfound" end), na, compile Σ b)
  | vConstruct i m [] =>
      match lookup_constructor_args Σ i with
      | Some num_args => let num_args_until_m := firstn m num_args in
                        let index := #| filter (fun x => match x with 0 => true | _ => false end) num_args_until_m| in
                        SemanticsSpec.value_Int (Malfunction.Int, BinInt.Z.of_nat index)
      | None => fail "inductive not found"
      end
  | vConstruct i m args =>
      match lookup_constructor_args Σ i with
      | Some num_args => let num_args_until_m := firstn m num_args in
                        let index := #| filter (fun x => match x with 0 => false | _ => true end) num_args_until_m| in
                        Block (int_of_nat index, map (compile_value Σ) args)
      | None => fail "inductive not found"
      end
  | vRecClos mfix idx env => 
       RClos ((fun x => match lookup (map (fun '(x,v) => (x, compile_value Σ v)) env) x with Some v => v | None => fail "notfound" end),
              (map fst mfix),
              map (fun '(_, b) => 
                match b with
                | EAst.tLambda na bd => RFunc ((BasicAst.string_of_name na), compile Σ bd)
                | _ => Bad_recursive_value
                end
              ) mfix,
              idx)
  end.
  
Require Import FunctionalExtensionality.

Lemma to_string_of_string s : 
  String.to_string (String.of_string s) = s.
Proof.
  induction s; cbn.
  - reflexivity.
  - now rewrite Ascii.ascii_of_byte_of_ascii, IHs.
Qed.

Lemma of_string_to_string s : 
  String.of_string (String.to_string s) = s.
Proof.
  induction s; cbn.
  - reflexivity.
  - now rewrite Ascii.byte_of_ascii_of_byte, IHs.
Qed.

Lemma lookup_map {A B} (f : A -> B) Γ x :
  lookup (map (fun '(x0, v) => (x0, f v)) Γ) x = option_map f (lookup Γ x).
Proof.
  unfold lookup.
  induction Γ as [ | []].
  - reflexivity.
  - cbn in *. change (String.eqb x i) with (eqb x i). destruct (eqb_spec x i).
    + subst. reflexivity.
    + eapply IHΓ.
Qed.

Lemma lookup_add a v Γ na :
  lookup (add a v Γ) na = if na == a then Some v else lookup Γ na.
Proof.
  unfold add, lookup. cbn. change (String.eqb na a) with (na == a).
  destruct (eqb_spec na a); congruence.
Qed.

Require Import Lia.

Lemma lookup_multiple nms args Γ na :
  List.length nms = List.length args ->
  lookup (add_multiple nms args Γ) na = match find (fun x => na == fst x) (map2 pair nms args) with 
                                        | Some (_, y) => Some y
                                        | None => lookup Γ na
                                        end.
Proof.
  intros Hlen. induction nms in args, Hlen |- *.
  - destruct args; cbn in *; congruence.
  - destruct args; cbn in *; try congruence.
    rewrite lookup_add, IHnms. 2: cbn in *; lia.
    destruct (eqb_spec na a).
    + eauto.
    + reflexivity.
Qed.

Arguments SemanticsSpec.eval {_}.

Fixpoint Mnapply (l : Malfunction.t) (args : list Malfunction.t) :=
  match args with
    [] => l
  | a :: args => Mnapply (Mapply_ (l, [a])) args
  end.

Lemma Mnapply_app l args1 args2 :
  Mnapply l (args1 ++ args2) = Mnapply (Mnapply l args1) args2.
Proof.
  induction args1 in l, args2 |- *; cbn.
  - reflexivity.
  - now rewrite IHargs1.
Qed. 

Lemma eval_app_nested_ `{Hp : Heap} globals locals args l args' v h h' :
  SemanticsSpec.eval globals locals h (Mnapply l (args' ++ args)) h' v ->
  SemanticsSpec.eval globals locals h (Mapply_ (Mnapply l args', args)) h' v.
Proof.
  induction args in args' |- *.
  - cbn. now rewrite app_nil_r.
  - cbn. intros H. specialize (IHargs (args' ++ [a])%list). destruct args.
    + now rewrite Mnapply_app in H.
    + econstructor. cbn in *.
      rewrite !Mnapply_app in IHargs.
      eapply IHargs. rewrite Mnapply_app in H. cbn in H.
      cbn. eauto.
Qed.

Lemma eval_app_nested_inv `{Hp : Heap} globals locals args l args' v h h' :
  SemanticsSpec.eval globals locals h (Mapply_ (Mnapply l args', args)) h' v ->
  SemanticsSpec.eval globals locals h (Mnapply l (args' ++ args)) h' v.
Proof.
  induction args in args' |- *.
  - cbn. now rewrite app_nil_r.
  - cbn. intros H. specialize (IHargs (args' ++ [a])%list). destruct args.
    + rewrite Mnapply_app. cbn. eauto.
    + cbn in *. rewrite <- app_assoc in *. cbn in IHargs.
      eapply IHargs.
      inversion H; subst.
      rewrite Mnapply_app. eauto.
Qed.

Lemma Mapply_eval `{H : Heap} globals locals (x : Malfunction.Ident.t)
    (locals' : Malfunction.Ident.Map.t)
    (e e2 : Malfunction.t) (v2 : SemanticsSpec.value)
    (e1 : Malfunction.t) (v : SemanticsSpec.value) args h1 h2 h3 h4 :
    SemanticsSpec.eval globals locals h1 (Mapply_ (e1, args)) h2 (Func (locals', x, e)) ->
    SemanticsSpec.eval globals locals h2 e2 h3 v2 ->
    SemanticsSpec.eval globals (Malfunction.Ident.Map.add x v2 locals') h3 e h4 v ->
    SemanticsSpec.eval globals locals h1 (Malfunction.Mapply (e1, args ++ [e2]))%list h4 v.
Proof.
  replace e1 with (Mnapply e1 []) by reflexivity.
  generalize (@nil Malfunction.t) at 1 2.
  induction args in e1 |- *; intros l Hleft Hright Happ; cbn.
  - econstructor; cbn in *; eauto.
  - cbn. econstructor.
    replace (Malfunction.Mapply (Mnapply e1 l, [a])) with
    (Mnapply e1 (l ++ [a])) by now rewrite Mnapply_app. cbn.
    eapply IHargs; eauto.
    cbn in Hleft.
    eapply eval_app_nested_inv with (args := a :: args) in Hleft.
    eapply eval_app_nested_. now rewrite <- app_assoc.
Qed.

Lemma Mapply_eval_rec `{H : Heap} globals locals (x : Malfunction.Ident.t)
    (locals' : Malfunction.Ident.Map.t)
    (e2 : Malfunction.t) (v2 : SemanticsSpec.value)
    (e1 : Malfunction.t) (v : SemanticsSpec.value) args h1 h2 h3 h4 
    self mfix n e :
    nth n mfix Bad_recursive_value = RFunc (x , e) -> 
    SemanticsSpec.eval globals locals h1 (Mapply_ (e1, args)) h2 (RClos (locals', self, mfix, n)) ->
    SemanticsSpec.eval globals locals h2 e2 h3 v2 ->
    SemanticsSpec.eval globals (Malfunction.Ident.Map.add x v2 (add_self self mfix locals')) h3 e h4 v ->
    SemanticsSpec.eval globals locals h1 (Malfunction.Mapply (e1, args ++ [e2]))%list h4 v.
Proof.
  replace e1 with (Mnapply e1 []) by reflexivity.
  generalize (@nil Malfunction.t) at 1 2.
  induction args in e1 |- *; intros l Hnth Hleft Hright Happ; cbn.
  - eapply eval_app_sing_rec; eauto.
  - cbn. econstructor.
    replace (Malfunction.Mapply (Mnapply e1 l, [a])) with
    (Mnapply e1 (l ++ [a])) by now rewrite Mnapply_app. cbn.
    eapply IHargs; eauto.
    cbn in Hleft.
    eapply eval_app_nested_inv with (args := a :: args) in Hleft.
    eapply eval_app_nested_. now rewrite <- app_assoc.
Qed.

Lemma Mapply_u_spec f a :
   ~ (exists n, f = Malfunction.Mapply (n, [])) ->
   (exists fn args, f = Mapply_ (fn, args) /\ Mapply_u f a = Mapply_ (fn, args ++ [a]))%list \/
   (~ (exists fn args, f = Malfunction.Mapply (fn, args)) /\ Mapply_u f a = Mapply_ (f, [a])).
Proof.
  destruct f; cbn; firstorder try congruence.
  left. destruct p. exists t, l; cbn. destruct l; cbn; eauto.
  edestruct H; eauto.
Qed.  

Lemma lookup_env_In d Σ : 
  EGlobalEnv.lookup_env Σ (fst d) = Some (snd d) -> In d Σ.
Proof.
  induction Σ; cbn in *.
  - congruence.
  - destruct (eqb_spec (fst d) (fst a)). intros [=]. destruct a, d; cbn in *; intuition auto.
    left; subst; auto.
    intros hl; specialize (IHΣ hl); intuition auto.
Qed.

(* Fixpoint add_recs'' (locals : Malfunction.Ident.Map.t) allrecs recs  := *)
(*   match recs with *)
(*   | [] => locals *)
(*   | (x, (y, e)) :: recs =>   *)
(*     let locals' := add_recs'' locals allrecs recs in *)
(*     Malfunction.Ident.Map.add x (Func (y, locals, Malfunction.Mlet ([Malfunction.Recursive allrecs], e))) locals' *)
(*   end. *)

(* Lemma add_recs''_spec locals allrecs recs x y t : *)
(*   NoDup (map fst recs) -> *)
(*   In (x, (y, t)) recs -> *)
(*   Malfunction.Ident.Map.find x (add_recs'' locals allrecs recs) = *)
(*   (Func (y, locals, Malfunction.Mlet ([Malfunction.Recursive allrecs], t))). *)
(* Proof. *)
(*   intros Hdup Hin. induction recs. *)
(*   - cbn in *. tauto. *)
(*   - cbn in *. inversion Hdup as [ | a_ b Hdup1 Hdup2 e ]; subst. *)
(*     destruct Hin. *)
(*     + subst. unfold Malfunction.Ident.Map.add, Malfunction.Ident.eqb. now rewrite String.eqb_refl. *)
(*     + destruct a as [? [] ]. unfold Malfunction.Ident.Map.add, Malfunction.Ident.eqb. *)
(*       destruct (String.eqb_spec x t0). *)
(*       * subst. cbn in *. destruct Hdup1. eapply in_map_iff. eexists (_ ,(_, _)); cbn. eauto. *)
(*       * eapply IHrecs; eauto. *)
(* Qed. *)

(* Lemma add_recs''_not locals allrecs recs x : *)
(*   ~ In x (map fst recs) -> *)
(*   Malfunction.Ident.Map.find x (add_recs'' locals allrecs recs) = *)
(*     locals x. *)
(* Proof. *)
(*   intros Hin. induction recs. *)
(*   - cbn in *. tauto. *)
(*   - cbn in *. destruct a. destruct p. *)
(*     cbn in *. *)
(*     unfold Malfunction.Ident.Map.add. *)
(*     unfold Malfunction.Ident.eqb. destruct (String.eqb_spec x t). *)
(*     + subst. destruct Hin; eauto. *)
(*     + eapply IHrecs. firstorder. *)
(* Qed. *)

Lemma Mapply_spec fn args : 
  args <> nil ->
  Mapply_ (fn, args) = Malfunction.Mapply (fn, args).
Proof.
  destruct args; cbn; congruence.
Qed.

Lemma All2_nth_error_Some_right {A B} {P : A -> B -> Type} {l l'} n t :
  All_Forall.All2 P l l' ->
  nth_error l' n = Some t ->
  { t' : A & (nth_error l n = Some t') * P t' t}%type.
Proof.
  intros Hall. revert n.
  induction Hall; destruct n; simpl; try congruence. intros [= ->]. exists x. intuition auto.
  eauto.
Qed.

Lemma eval_Mvar `{Hp : Heap} globals (locals : Malfunction.Ident.Map.t) (id : Malfunction.Ident.t) v h :
  v = (Malfunction.Ident.Map.find id locals) ->
  SemanticsSpec.eval globals locals h (Malfunction.Mvar id) h v.
Proof.
  intros ->. econstructor.
Qed.

Lemma eval_num `{Heap} Σ Γ_ i z h : 
  BinInt.Z.le BinNums.Z0 z ->
  BinInt.Z.lt z Malfunction.Int63.wB ->
  Uint63.of_Z z = i ->
  SemanticsSpec.eval Σ Γ_ h
    (Malfunction.Mnum
       (Malfunction.numconst_Int i)) h
    (value_Int
       (Malfunction.Int, z)).
Proof.
  intros. subst.
  pose proof (Malfunction.Int63.of_Z_spec z) as Heq.
  rewrite Zdiv.Zmod_small in Heq; [| lia_max_length]. rewrite <- Heq at 2.
  econstructor.
Qed. 

(*   todo "missing eval_num"%bs. eauto.
Qed.
 *)    
 
Lemma find_add_self {Hp : Heap} idx d na recs locals :
  NoDup (map fst recs) ->
  nth_error recs idx = Some (na, d) ->
  Malfunction.Ident.Map.find na (add_self (map fst recs) (RFunc_build (map snd recs)) locals)
  = RClos (locals, map fst recs, RFunc_build (map snd recs), idx).
Proof.
  intros Hdup Hnth. unfold add_self, add_recs, List.mapi.
  unfold Malfunction.Ident.Map.find.
  revert Hnth Hdup.
  change idx with (0 + idx) at 2.
  generalize 0 as i.
  generalize recs at 1 2 5. induction recs0 in recs, locals, idx |- *; intros.
  - destruct idx; cbn in *; congruence.
  - cbn. destruct a as [na' e]. 
    destruct idx; cbn in Hnth; inversion Hnth.
    + subst. unfold Malfunction.Ident.Map.add, Malfunction.Ident.eqb.
      rewrite eqb_refl. repeat f_equal. lia.  
    + unfold Malfunction.Ident.Map.add, Malfunction.Ident.eqb.
      cbn. destruct (eqb_spec na na').
      * subst. exfalso. inversion Hdup; subst. eapply H2.
        eapply nth_error_In. rewrite nth_error_map, H0. reflexivity.
      * eapply IHrecs0 in Hnth. cbn. rewrite Hnth. f_equal. f_equal. lia. now inversion Hdup.
Qed.

Lemma nth_error_fix_env idx mfix Γ : 
  idx < #|mfix| ->
  nth_error (fix_env mfix Γ) idx = Some (vRecClos mfix (#|mfix| - S idx) Γ).
Proof.
  unfold fix_env. induction #|mfix| in idx |- *; cbn.
  - lia.
  - intros. destruct idx.
    + cbn. now rewrite Nat.sub_0_r.
    + cbn. eapply IHn. lia.
Qed.

Lemma add_self_lookup {Hp : Heap} Σ recs (na : Malfunction.Ident.t) locals locals' mfix nms bodies : 
  Forall2 (fun '(na1, e1) '(na2, e2) => na2 = na1 /\ e1 = compile Σ e2) recs mfix ->
  (forall na, locals na = match lookup locals' na with Some v => compile_value Σ v | None => fail "notfound" end) ->
  nms = (map fst recs) ->
  bodies = (RFunc_build (map snd recs)) ->
  NoDup nms ->
  forallb (fun b => EAst.isLambda b.2) mfix ->
  Malfunction.Ident.Map.find (na) (add_self nms bodies locals) =
    match lookup (add_multiple (List.rev (map fst mfix)) (fix_env mfix locals') locals') na with
    | Some v => compile_value Σ v
    | None => fail "notfound"
    end.
Proof. 
  intros Hall Hlocals -> -> Hdup Hlam.
  rewrite lookup_multiple.
  destruct find eqn:E.
  + destruct p as [na' v]. eapply find_some in E as [H1 H2].
    cbn in *. eapply eqb_eq in H2. subst. 
    eapply In_nth_error in H1 as [idx H].
    eapply PCUICReduction.nth_error_map2 in H as (na_ & v_ & [H1 H2] & [= <- <-]).
    assert (idx < #|mfix|). { erewrite <- fix_env_length. eapply nth_error_Some. rewrite H2. congruence. }
    rewrite nth_error_fix_env in H2. 2: eauto.
    inversion H2; subst; clear H2.
    rewrite nth_error_rev_inv in H1. 2: now rewrite map_length.
    rewrite map_length in H1.
    rewrite nth_error_map in H1. destruct (nth_error) eqn:E; cbn in *; inversion H1; subst; clear H1.
    eapply Forall2_nth_error_Some_r in Hall as Hs. destruct Hs as (? & ? & ?). 2: eauto.
    destruct x. destruct p. destruct H1. subst.
    erewrite find_add_self. 3: eauto.
    repeat f_equal.
    - eapply functional_extensionality. intros x.
      specialize (Hlocals (x)). 
      rewrite Hlocals. rewrite lookup_map. now destruct lookup.
    - clear - Hall. induction Hall; cbn; f_equal; eauto.
      destruct x, y; cbn in *. destruct H; subst. reflexivity.
    - unfold RFunc_build. clear - Hall Hlam. induction Hall; cbn in *; f_equal; rtoProp; eauto.
      destruct x, y; cbn in *; rtoProp. destruct H. subst.
      destruct t2; cbn in *; eauto. now simp compile.
    - eauto.
  + pose proof (find_none _ _ E). cbn in *.
    rewrite <- Hlocals. clear E.
    unfold add_self, add_recs, List.mapi. generalize 0.
    generalize (RFunc_build (map snd recs)).
    generalize (map fst recs) at 1.
    assert (forall x, In x (map fst mfix) -> na <> x). {
      intros ? ? ->.
      enough (exists y, In (x, y) (map2 pair (List.rev (map fst mfix)) (fix_env mfix locals'))) as [].
      eapply H in H1. change string with Malfunction.Ident.t in *. cbn in *.
      destruct (eqb_spec x x); try congruence. clear - H0.
      unfold fix_env. generalize mfix at 2. induction mfix using rev_ind; cbn in *; eauto; intros.
      rewrite map_app, in_app_iff in H0. cbn in H0.
      rewrite app_length. cbn. rewrite Nat.add_comm. cbn. rewrite map_app. cbn.
      rewrite rev_app_distr. cbn.
      destruct H0 as [ | [ | []]].
      - edestruct IHmfix; eauto.
      - subst. cbn. eauto.
    } clear H.
    induction Hall; intros.
    * cbn. reflexivity.
    * cbn. destruct x. unfold Malfunction.Ident.Map.add, Malfunction.Ident.eqb.
      -- cbn. destruct (eqb_spec na t).
         ++ subst. exfalso. cbn in *. eapply H0. left. reflexivity.
            destruct y; cbn in *. destruct H. congruence.
         ++ eapply IHHall. now inversion Hdup. cbn in *; rtoProp. tauto. intros. eapply H0. cbn. eauto.
  + now rewrite List.rev_length, map_length, fix_env_length.
Qed.

Opaque Malfunction.Int63.wB PArray.max_length.

Lemma compile_correct `{Hp : Heap} Σ Σ' s t Γ Γ' h :
  (forall i mb ob, EGlobalEnv.lookup_inductive Σ i = Some (mb, ob) -> #|ob.(EAst.ind_ctors)| < Z.to_nat Malfunction.Int63.wB /\ forall n b, nth_error ob.(EAst.ind_ctors) n = Some b -> b.(EAst.cstr_nargs) < int_to_nat PArray.max_length) ->
  (forall na, Malfunction.Ident.Map.find na Γ' =  match lookup Γ na with Some v => compile_value Σ v | _ => fail "notfound" end) ->
  (forall c decl body v, EGlobalEnv.declared_constant Σ c decl -> EAst.cst_body decl = Some body -> EWcbvEvalNamed.eval Σ [] body v -> In ((Kernames.string_of_kername c), compile_value Σ v) Σ') ->
   EWcbvEvalNamed.eval Σ Γ s t ->
   SemanticsSpec.eval Σ' Γ' h (compile Σ s) h (compile_value Σ t).
Proof.
  intros Hextr HΓ HΣ Heval.
  revert Γ' HΓ.
  induction Heval; intros Γ_ HΓ; simp compile; try rewrite <- !compile_equation_1.
  - (* variables *)
    specialize (HΓ na).
    unfold EWcbvEvalNamed.lookup, lookup in *.
    rewrite e in HΓ. rewrite <- HΓ.
    econstructor.
  (* - (* box app *) *)
  (*   cbn. *)
  (*   destruct (Mapply_u_spec (compile Σ a) (compile Σ t)) as [(fn & arg & E & ->) | (E & ->) ]. *)
  (*   + destruct a; simp compile; intros [? [=]]. *)
  (*     * destruct (compile Σ a1); cbn in H0; try congruence. destruct p, l; cbn in *; congruence. *)
  (*     * revert H0. destruct l; simp compile; destruct lookup_constructor_args; cbn. *)
  (*       all: congruence. *)
  (*     * revert H0. destruct l; simp compile; destruct lookup_constructor_args; cbn in *; congruence. *)
  (*     * revert H0. destruct p. simp compile. unfold compile_unfold_clause_11. *)
  (*       destruct lookup_record_projs; congruence. *)
  (*     * revert H0. destruct p; cbn. unfold to_primitive. cbn. destruct p; cbn; congruence. *)
  (*   + rewrite Mapply_spec. 2: destruct arg; cbn; congruence. *)
  (*     eapply Mapply_eval_rec. *)
  (*     2:{ rewrite <- E. eapply IHHeval1; eauto. } *)
  (*     * reflexivity. *)
  (*     * eapply IHHeval2; eauto. *)
  (*     * unfold add_self. cbn. econstructor. *)
  (*   + cbn. eapply eval_app_sing_rec. *)
  (*     * eapply IHHeval1; eauto. *)
  (*     * eapply IHHeval2; eauto. *)
  (*     * reflexivity. *)
  (*     * econstructor. *)
  - (* beta *)
    destruct (Mapply_u_spec (compile Σ f1) (compile Σ a)) as [(fn & arg & E & ->) | (E & ->) ].
    + destruct f1; simp compile; intros [? [=]].
      * destruct (compile Σ f1_1); cbn in H0; try congruence. destruct p, l; cbn in *; congruence.
      * revert H0. destruct l; simp compile; destruct lookup_constructor_args; cbn.
        all: congruence.
      * revert H0. destruct l; simp compile; try congruence.
        destruct lookup_constructor_args; cbn in *; congruence.
      * revert H0. destruct p. simp compile. unfold compile_unfold_clause_11.
        destruct lookup_record_projs; congruence.
      * revert H0. destruct p; cbn. unfold to_primitive. cbn. destruct p; cbn; congruence.
    + rewrite Mapply_spec. 2: destruct arg; cbn; congruence.
      eapply Mapply_eval.
      * rewrite <- E. cbn in IHHeval1. eauto.
      * eauto.
      * erewrite (functional_extensionality ((Malfunction.Ident.Map.add (na)
             (compile_value Σ a')
             (fun x : Malfunction.Ident.t =>
              match
                lookup (map (fun '(x0, v) => (x0, compile_value Σ v)) Γ')
                  (x)
              with
              | Some v => v
              | None => fail "notfound"
              end))) (fun na0 => match lookup (add na a' Γ') (na0) with
              | Some v => compile_value Σ v
              | None => fail "notfound"
              end)). eapply IHHeval3.
        -- intros na0. unfold Malfunction.Ident.Map.find. congruence.
        -- intros x.  unfold Malfunction.Ident.Map.find. rewrite lookup_add.
           unfold Malfunction.Ident.Map.add. unfold Malfunction.Ident.eqb.
           destruct (eqb_spec x na).
           ++ subst. now rewrite eqb_refl.
           ++ change string with Malfunction.Ident.t in *. destruct (eqb_spec x na).
              ** subst. congruence.
              ** rewrite lookup_map. now destruct lookup.
    + econstructor. cbn in *. eauto. eauto.
      erewrite (functional_extensionality ((Malfunction.Ident.Map.add (na)
             (compile_value Σ a')
             (fun x : Malfunction.Ident.t =>
              match
                lookup (map (fun '(x0, v) => (x0, compile_value Σ v)) Γ')
                  (x)
              with
              | Some v => v
              | None => fail "notfound"
              end))) (fun na0 => match lookup (add na a' Γ') (na0) with
              | Some v => compile_value Σ v
              | None => fail "notfound"
              end)). eapply IHHeval3.
        -- intros na0. unfold Malfunction.Ident.Map.find. congruence.
        -- intros x.  unfold Malfunction.Ident.Map.find. rewrite lookup_add.
           unfold Malfunction.Ident.Map.add. unfold Malfunction.Ident.eqb.
           change string with Malfunction.Ident.t in *.
           destruct (eqb_spec x (na)).
           ++ subst. congruence.
           ++ rewrite lookup_map. now destruct lookup.
  - (* lambda *)
    cbn.
    erewrite (functional_extensionality (fun x : Malfunction.Ident.t => match lookup (map (fun '(x0, v) => (x0, compile_value Σ v)) Γ) (x) with
                                       | Some v => v
                                       | None => fail "notfound"
                                       end)).
    econstructor.
    intros x. specialize (HΓ (x)).
    unfold Malfunction.Ident.Map.find in HΓ.
    rewrite HΓ.
    rewrite lookup_map.
    now destruct lookup.
  - (* let *)
    cbn. econstructor.
    + now eapply IHHeval1.
    + econstructor. eapply IHHeval2.
      intros. unfold add, lookup in *. cbn in *.
      change (String.eqb na0 na) with (na0 == na) in *.
      destruct (eqb_spec na0 na).
      * subst. unfold Malfunction.Ident.Map.add, Malfunction.Ident.Map.find, Malfunction.Ident.eqb.
        now rewrite eqb_refl.
      * unfold Malfunction.Ident.Map.add, Malfunction.Ident.Map.find, Malfunction.Ident.eqb.
        destruct (eqb_spec na0 na).
        -- congruence.
        -- rewrite <- HΓ. reflexivity.
  - (* case *)
    destruct brs.
    { destruct c; invs e1. }
    simp compile. set (p :: brs) as brs' in *. clearbody brs'. clear p brs. rename brs' into brs.
    destruct br as [nms' b].
    destruct nms'.
    + Arguments Mcase : simpl never.
      cbn -[EGlobalEnv.lookup_inductive] in *. inversion f4; cbn -[Mcase EGlobalEnv.lookup_inductive] in *; try congruence. subst.
      destruct args; cbn -[EGlobalEnv.lookup_inductive] in *; try congruence.
      unfold EGlobalEnv.constructor_isprop_pars_decl, lookup_constructor_args, EGlobalEnv.lookup_constructor in *;
      destruct (EGlobalEnv.lookup_inductive) as [ [] | ] eqn:Elo; cbn -[EGlobalEnv.lookup_inductive] in *; try congruence.
      specialize (Hextr _ _ _ Elo) as [He1 He2].
      destruct nth_error eqn:Econ; try congruence.
      specialize (He2 _ _ Econ).
      eapply eval_case_int.
      2: { rewrite map_length. cbn. lia. }
      4:{ eapply IHHeval2; eauto. }
      2:{ rewrite nth_error_map, Econ. cbn. destruct c0; cbn in *; subst. inversion e0; subst. destruct m; cbn in *; subst. reflexivity. }
      eapply IHHeval1. eauto.
      rewrite map_InP_spec. rewrite nth_error_map, e1. cbn. reflexivity.
    +  cbn -[lookup EGlobalEnv.lookup_inductive] in *. inversion f4; cbn -[Mcase lookup EGlobalEnv.lookup_inductive] in *; try congruence. subst. clear f4.
       destruct args; cbn -[lookup add_multiple EGlobalEnv.lookup_inductive] in *; try congruence.
       unfold EGlobalEnv.constructor_isprop_pars_decl, lookup_constructor_args, EGlobalEnv.lookup_constructor in *;
       destruct (EGlobalEnv.lookup_inductive) as [ [] | ] eqn:Elo; cbn -[add_multiple EGlobalEnv.lookup_inductive] in *; try congruence.
       specialize (Hextr _ _ _ Elo) as [He1 He2].
       eapply Forall2_length in H3 as Hll.
       destruct nth_error eqn:Econ; try congruence.
       specialize (He2 _ _ Econ).
       eapply eval_case_block.
       7: eapply NoDup_rev; eauto. 2:{ cbn.  destruct (@List.rev Malfunction.Ident.t (l')); cbn; try congruence. }
       eapply IHHeval1. eauto.
       1:{ rewrite map_length. cbn. lia. }
       1:{ cbn. rewrite map_length. rewrite e2. cbn. invs e0. lia. }
       rewrite nth_error_map, Econ. cbn. destruct c0; cbn in *; subst. inversion e0; subst. destruct m; cbn in *; subst. repeat f_equal.
       rewrite app_length. rewrite List.rev_length.
       setoid_rewrite <- Hll. cbn. lia.
       rewrite map_InP_spec. rewrite nth_error_map. 
       rewrite e1. cbn [option_map].
       rewrite rev_map_spec. cbn. repeat f_equal.
       { clear - H3. induction H3; cbn; f_equal; subst; cbn; eauto. }
       cbn. f_equal. rewrite map_length. rewrite app_length. rewrite List.rev_length.
       setoid_rewrite <- Hll. cbn. lia. 
       eapply IHHeval2. intros.
       cbn [List.rev].
       assert (#|List.rev l' ++ [y]| = List.length ((compile_value Σ v :: map (compile_value Σ) args))).
       { rewrite app_length, List.rev_length. cbn. rewrite map_length. lia. }
       revert H. unfold Kernames.ident, Malfunction.Ident.t in *. clear - HΓ.
       generalize (List.rev l' ++ [y])%list. intros.
       destruct l; cbn in *; try congruence. 
       unfold lookup. cbn. unfold Malfunction.Ident.Map.add. cbn.
       unfold Malfunction.Ident.eqb. change (String.eqb na t) with (na == t).
       unfold Kernames.ident, Malfunction.Ident.t in *.
       destruct (eqb_spec na t); try congruence. invs H. clear H0 H2.
       induction l in args |- *; cbn.
       -- destruct args; cbn. all: eapply HΓ.
       -- destruct args; cbn. eapply HΓ.
          unfold Malfunction.Ident.eqb. change (String.eqb na a) with (na == a).
          unfold Kernames.ident, Malfunction.Ident.t in *.
          destruct (eqb_spec na a); eauto.
   - (* recursion *)
    cbn.
    cbn - [compile_value] in *. subst.
    destruct (Mapply_u_spec (compile Σ f5) (compile Σ a)) as [(fn_ & arg & E & ->) | (E & ->) ].
    + destruct f5; simp compile; intros [? [=]].
      * destruct (compile Σ f5_1); cbn in H0; try congruence. destruct p, l; cbn in *; congruence.
      * revert H0. destruct l; simp compile; destruct lookup_constructor_args; cbn.  all: congruence.
      * revert H0. destruct l; simp compile; try congruence.
        destruct lookup_constructor_args; cbn; try congruence. unfold Mcase. congruence.
      * revert H0. destruct p; simp compile. unfold compile_unfold_clause_11.
        destruct lookup_record_projs; cbn; congruence.
      * revert H0. repeat destruct p; cbn; try congruence. 
    + rewrite Mapply_spec. 2: destruct arg; cbn; congruence.
      eapply Mapply_eval_rec. 2: rewrite <- E.
      2: cbn in IHHeval1.
      2: eapply IHHeval1. 2: eauto.
      * erewrite nth_error_nth. reflexivity.
        rewrite nth_error_map. rewrite e0. reflexivity.
      * eapply IHHeval3. eauto.
      * eapply IHHeval2. intros na0.
        rewrite lookup_add.
        unfold Malfunction.Ident.Map.find, Malfunction.Ident.Map.add, Malfunction.Ident.eqb. cbn.
        destruct (eqb_spec na0 na).
        -- subst. now rewrite eqb_refl.
        -- change string with Malfunction.Ident.t in *. destruct (eqb_spec na0 na).
           ++ exfalso. congruence.
           ++ eapply add_self_lookup.
              instantiate (1 := map (fun '(x, b) => (x, compile Σ b)) mfix).
              3:{ rewrite !map_map. eapply map_ext. intros []; cbn. reflexivity. }
              2:{ intros. rewrite lookup_map. now destruct lookup. }
              2:{ unfold RFunc_build. rewrite !map_map. eapply map_ext_in. intros [] ?; cbn.
                  eapply forallb_forall in Hbodies; eauto. cbn in *.
                  destruct t; cbn in *; try congruence.
                  now simp compile. }
                  clear.
              ** induction mfix; cbn; econstructor; eauto. destruct a; cbn. tauto.
              ** cbn. clear - n. 
                 induction mfix; cbn in *; inversion n; econstructor; eauto.
              ** eauto.
    + rewrite Mapply_spec. 2: congruence.
      eapply eval_app_sing_rec.
      * cbn in IHHeval1. eapply IHHeval1; eauto.
      * eauto.
      * erewrite nth_error_nth. reflexivity. rewrite nth_error_map, e0. cbn. reflexivity.
      * eapply IHHeval2. intros na0.
      rewrite lookup_add.
      unfold Malfunction.Ident.Map.find, Malfunction.Ident.Map.add, Malfunction.Ident.eqb. cbn.
        destruct (eqb_spec na0 na).
        -- subst. now rewrite eqb_refl.
        -- change string with Malfunction.Ident.t in *. destruct (eqb_spec na0 na).
           ++ exfalso. congruence.
           ++ eapply add_self_lookup.
              instantiate (1 := map (fun '(x, b) => (x, compile Σ b)) mfix).
              3:{ rewrite !map_map. eapply map_ext. intros []; cbn. reflexivity. }
              2:{ intros. rewrite lookup_map. now destruct lookup. }
              2:{ unfold RFunc_build. rewrite !map_map. eapply map_ext_in. intros [] ?; cbn.
                  eapply forallb_forall in Hbodies; eauto. cbn in *.
                  destruct t; cbn in *; try congruence.
                  now simp compile. }
                  clear.
              ** induction mfix; cbn; econstructor; eauto. destruct a; cbn. tauto.
              ** cbn. clear - n. 
                 induction mfix; cbn in *; inversion n; econstructor; eauto.
              ** eauto.
  - (* fix *)
    destruct ((MCList.nth_error_Some' mfix (idx))) as [_ Hnth].
    forward Hnth.
    assert (Datatypes.length mfix > 0) by lia.  1: lia.
    assert ({ l | Forall2 (fun d '(x, y, b) => d.(EAst.dname) = BasicAst.nNamed x /\ d.(EAst.dbody) = EAst.tLambda y b) mfix l /\
                  NoDup (map (fun x => fst (fst x)) l) }) as [l [Hl Hnodup]].
    {
     unfold is_true in Hbodies.
     rewrite forallb_forall, <- Forall_forall in Hbodies.
     clear - Hbodies n f6. eapply All_Forall.Forall2_All2 in f6. eapply All_Forall.Forall_All in Hbodies.
     induction f6.
     - exists []; repeat econstructor.
     - inversion Hbodies; subst. destruct IHf6 as [l_ Hl]; eauto. now inversion n; subst.
       destruct Hl. destruct x; cbn in *. destruct dbody; cbn in *; try congruence.
       eexists ((_, _, _) :: l_); cbn. repeat econstructor; eauto. cbn.
       intros (? & ? & ?) % in_map_iff. subst. inversion n; subst. eapply H5.
       eapply All_Forall.Forall2_All2 in H.
       eapply In_nth_error in H3 as [n_ Hn].
       eapply All2_nth_error_Some_right in H; eauto.
       destruct H as (? & ? & ?).
       destruct x, p, y; cbn in *; subst.
       eapply All_Forall.All2_nth_error_Some in f6; eauto.
       destruct f6 as (? & ? & ?). cbn in *.
       inversion e1; subst. destruct x0; cbn in *; subst. inversion H4; subst.
       eapply nth_error_In; eauto.
    }
    cbn -[compile_value]. 
    rewrite map_InP_spec.
    econstructor. econstructor. eapply eval_Mvar.
    (* rewrite !map_map. *)
    destruct Hnth as [[na fn] Hnth].
    cbn -[compile_value].
    erewrite nth_error_nth. 
    2:{ rewrite nth_error_map. rewrite Hnth. cbn. reflexivity. }
    erewrite find_add_self.
    2:{ rewrite map_map. cbn. clear - n f6. induction f6; inversion n; cbn; econstructor; eauto.
        subst. destruct x; cbn in *; subst. cbn.        
        intros (? & ? & ?) % in_map_iff. subst. eapply H2.
        eapply In_nth_error in H0 as []. 
        eapply Forall2_nth_error_Some in f6 as (? & ? & ?); eauto.
        eapply nth_error_In in H0.
        destruct x; cbn in *; subst.
        cbn. eauto.
    }
    2:{ rewrite nth_error_map. rewrite Hnth. cbn. reflexivity. }
    cbn. repeat f_equal.
    + eapply functional_extensionality. intros. specialize (HΓ (x)).
      unfold Malfunction.Ident.Map.find in HΓ. 
      rewrite HΓ. rewrite lookup_map. now destruct lookup.
    + rewrite !map_map. clear - f6. induction f6; cbn; f_equal; eauto.
      destruct x; cbn in *; subst. reflexivity.
    + clear - f6 Hbodies. induction f6; cbn; f_equal. 
      * destruct x; cbn in *. rtoProp. subst.
        destruct dbody; cbn in *; eauto. 
        now simp compile.
      * rewrite IHf6. 2: cbn in *; rtoProp; tauto.
        reflexivity.
  - (* global *)
    econstructor. eapply HΣ; eauto.
  - (* constructor application *)
    cbn. destruct args; simp compile;
    unfold lookup_constructor_args, EGlobalEnv.lookup_constructor in *;
      destruct (EGlobalEnv.lookup_inductive) as [ [] | ] eqn:Elo; cbn -[EGlobalEnv.lookup_inductive] in *; try congruence;
     specialize (Hextr _ _ _ Elo) as [He1 He2].
     + depelim a.
      eapply eval_num. lia. 2: reflexivity.
      assert (Z.of_nat #|EAst.ind_ctors o| < Malfunction.Int63.wB)%Z by (cbn; lia). 
      pose proof (filter_length (firstn c (map EAst.cstr_nargs (EAst.ind_ctors o))) (fun x : nat => match x with
        | 0%nat => true
        | S _ => false
        end)).
      rewrite firstn_length in H0.
      destruct nth_error eqn:E; try congruence.
      specialize (He2 _ _ E).
      eapply nth_error_Some_length in E. lia. 
    + depelim a. cbn.
      rewrite MCList.map_InP_spec.
      depelim IHa.
      cbn. econstructor. econstructor. eapply e1; eauto. clear e1.
      2:{ cbn. rewrite map_length. clear a0. eapply Prelim.Ee.All2_Set_All2 in a. eapply All2_length in a. rewrite <- a.
          assert (EAst.cstr_nargs cdecl < int_to_nat PArray.max_length). {  destruct nth_error eqn:E; try congruence.
          invs e. specialize (He2 _ _ E). cbn. lia. }
          cbn in *. lia. }      
      induction a.
      * econstructor.
      * cbn. econstructor.
        -- eapply a0; eauto.
        -- eapply IHa; eauto. cbn in l. lia. eapply a0.      
  - cbn. unfold lookup_constructor_args, EGlobalEnv.lookup_constructor in *;
      destruct (EGlobalEnv.lookup_inductive) as [ [] | ] eqn:Elo; cbn -[EGlobalEnv.lookup_inductive] in *; try congruence.
    eapply eval_num. lia. 2:reflexivity.
    assert (Z.of_nat #|EAst.ind_ctors o| < Malfunction.Int63.wB)%Z. { specialize (Hextr _ _ _ Elo) as [He1 He2]. cbn. lia. }
    pose proof (filter_length (firstn c (map EAst.cstr_nargs (EAst.ind_ctors o))) (fun x : nat => match x with
      | 0%nat => true
      | S _ => false
      end)).
    rewrite firstn_length in H0.
    destruct nth_error eqn:E; try congruence.
    eapply nth_error_Some_length in E. lia.
Qed.
Print Assumptions compile_correct.

Definition binding_names (b : Malfunction.binding) :=
  match b with
  | Malfunction.Unnamed _ => []
  | Malfunction.Named (x, _) => [x]
  | Malfunction.Recursive b => map fst b
  end.

Section fix_global.

  Variable Σ : list Malfunction.Ident.t.

  Fixpoint wellformed (Γ : list Malfunction.Ident.t) (t : Malfunction.t) :=
    match t with
    | Malfunction.Mvar x => match in_dec eq_dec x Γ with left _ => true | _ => false end
    | Malfunction.Mlambda (ids, x) => negb (EWellformed.is_nil ids) && wellformed (ids ++ Γ) x
    | Malfunction.Mapply (x, args) => negb (EWellformed.is_nil args) && wellformed Γ x && forallb (wellformed Γ) args
    | Malfunction.Mlet (binds, x) => negb (EWellformed.is_nil binds) && forallb (wellformed_binding Γ) binds && wellformed (flat_map binding_names binds ++ Γ) x
    | Malfunction.Mnum x => true
    | Malfunction.Mstring x => true
    | Malfunction.Mglobal id =>
        match
        in_dec eq_dec id Σ
        with left _ => true | _ => false end
    | Malfunction.Mswitch (x, sels) =>  negb (EWellformed.is_nil sels) && wellformed Γ x && forallb (fun '(_, x) => wellformed Γ x) sels
    | Malfunction.Mnumop1 (op, num, x) => wellformed Γ x
    | Malfunction.Mnumop2 (op, num, x1, x2) => wellformed Γ x1 && wellformed Γ x2
    | Malfunction.Mconvert (from, to, x) => wellformed Γ x
    | Malfunction.Mvecnew (ty, x1, x2) => wellformed Γ x1 && wellformed Γ x2
    | Malfunction.Mvecget (ty, x1, x2) => wellformed Γ x1 && wellformed Γ x2
    | Malfunction.Mvecset (ty, x1, x2, x3) => wellformed Γ x1 && wellformed Γ x2 && wellformed Γ x3
    | Malfunction.Mveclen (ty, x) => wellformed Γ x
    | Malfunction.Mlazy x => wellformed Γ x
    | Malfunction.Mforce x => wellformed Γ x
    | Malfunction.Mblock (tag, xs) => forallb (wellformed Γ) xs
    | Malfunction.Mfield (i, x) => wellformed Γ x
    end
  with wellformed_binding Γ (b : Malfunction.binding) :=
         match b with
         | Malfunction.Unnamed x => wellformed Γ x
         | Malfunction.Named (id, x) => wellformed Γ x
         | Malfunction.Recursive recs => forallb (fun '(id,x) => wellformed (List.rev (map fst recs) ++ Γ) x) recs
         end.

End fix_global.

Lemma wellformed_Mapply_ Σ Γ x args :
  wellformed Σ Γ x -> forallb (wellformed Σ Γ) args -> wellformed Σ Γ (Mapply_ (x, args)).
Proof.
  intros. unfold Mapply_. destruct args.
  - eauto.
  - cbn in *; rtoProp; eauto.
Qed.

Lemma wellformed_Mlambda_ Σ Γ x ids :
  wellformed Σ (ids ++ Γ) x -> wellformed Σ Γ (Mlambda_ (ids, x)).
Proof.
  intros. unfold Mapply_. destruct ids.
  - eauto.
  - cbn in *; rtoProp; eauto.
Qed.

Fixpoint wellformed_subset Σ Γ1 Γ2 x :
  incl Γ2 Γ1 -> wellformed Σ Γ2 x -> wellformed Σ Γ1 x
with wellformed_binding_subset Σ Γ1 Γ2 x :
  incl Γ2 Γ1 -> wellformed_binding Σ Γ2 x -> wellformed_binding Σ Γ1 x.
Proof.
  2: destruct x. destruct x.
  all: intros Hincl Hwf; cbn in *; eauto.
  - destruct in_dec; try congruence.
    destruct in_dec; firstorder congruence.
  - destruct p. rtoProp. split. eauto.
    eapply wellformed_subset. 2: eauto. intros ?. rewrite !in_app_iff.
    intros [ | ? % Hincl]; auto.
  - destruct p. rtoProp. repeat split; auto.
    + eapply wellformed_subset; eauto.
    + clear H. induction l.
      * econstructor.
      * cbn in *. rtoProp. split. eapply wellformed_subset; eauto. eapply IHl; eauto.
  - destruct p. rtoProp. repeat split; eauto.
    2:{ eapply wellformed_subset; eauto. intros ?. rewrite !in_app_iff. intros [ | ? % Hincl]; eauto. }
    clear H H0. induction l.
    + econstructor.
    + cbn in *. rtoProp. split. eapply wellformed_binding_subset; eauto. eapply IHl; eauto.
  - destruct p. rtoProp. repeat split; eauto.
    clear H. induction l; cbn in *.
    + econstructor.
    + destruct a. rtoProp. split; eauto.
  - destruct p as [ [] ]. eauto.
  - destruct p as [ [[]] ]. rtoProp. split; eauto.
  - destruct p as [ [] ]. eauto.
  - destruct p as [ [ ] ]; rtoProp. split; eauto.
  - destruct p as [ [] ]; rtoProp. split; eauto.
  - destruct p as [ [[]] ]. rtoProp. split; eauto.
  - destruct p; rtoProp; eauto.
  - destruct p. induction l; cbn in *; eauto.
    rtoProp; split; eauto.
  - destruct p; rtoProp; eauto.
  - destruct p; rtoProp; eauto.
  - revert Hwf. generalize l at 1 3. induction l; cbn in *.
    + eauto.
    + intros. destruct a. rtoProp. split; eauto.
      eapply wellformed_subset. 2: eauto.
      intros ?. rewrite !in_app_iff. intros [ ] ; eauto.
Qed.

Lemma compile_wellformed (efl := EWcbvEvalNamed.extraction_env_flags) Γ n s t (Σ : EAst.global_declarations) :
  EWellformed.wellformed Σ n t ->
  represents Γ [] s t ->
  wellformed (map (fun '(i,_) => Kernames.string_of_kername i) Σ) Γ (compile Σ s).
Proof.
  intros Hwf Hrep. revert n Hwf.
  remember [] as E. revert HeqE.
  eapply @represents_ind with (e := E) (l := Γ) (t := s) (t0 := t) (P0 := fun _ _ _ => True); intros; simp compile;
    cbn [EWellformed.wellformed] in *;
    subst; try now tauto.
  - cbn. eapply nth_error_In  in e. destruct in_dec; eauto; tauto.
  - cbn in e. congruence.
  - cbn. rtoProp. repeat split; eauto. 
  - unfold Mapply_u. destruct (compile Σ s0); cbn; rtoProp; try split; eauto.
    destruct p; cbn. rtoProp; repeat split; eauto.
    + destruct l; cbn; split; eauto.
    + cbn in H. pose proof (H eq_refl _ H3). rtoProp. eauto.
    + rewrite forallb_app. cbn; rtoProp; repeat split; eauto.
      cbn in H. unshelve epose proof (H eq_refl _ _). 2: eauto.
      rtoProp. eauto.
  - cbn. rtoProp. cbn in *.
    destruct EGlobalEnv.lookup_env as [ [] | ] eqn: Eq; try congruence.
    eapply lookup_env_In with (d := (c, _)) in Eq.
    destruct in_dec; eauto.
    exfalso. eapply n0. eapply in_map_iff.
    eexists; split; eauto. cbn. eauto.
  - destruct args; simp compile.
    + rtoProp. unfold EGlobalEnv.lookup_constructor_pars_args, lookup_constructor_args, EGlobalEnv.lookup_constructor in *.
      cbn -[EGlobalEnv.lookup_inductive] in *.
      destruct EGlobalEnv.lookup_inductive as [ [] | ]; cbn; eauto.
    + rtoProp. unfold EGlobalEnv.lookup_constructor_pars_args, lookup_constructor_args, EGlobalEnv.lookup_constructor in *.
      cbn -[EGlobalEnv.lookup_inductive] in *.
      destruct EGlobalEnv.lookup_inductive as [ [] | ]; cbn; eauto.
      rtoProp. split.
      * depelim a. cbn in H2. rtoProp. destruct IH as [IH0 IH]. eapply IH0; eauto.
      * depelim a.  cbn in H2. rtoProp.
        eapply All_forallb.  rewrite map_InP_spec in *. clear - a IH H3.
        induction a; cbn. 1: constructor.
        cbn in H3. rtoProp. econstructor. eapply IH; eauto.
        eapply IHa; eauto.  cbn. split; eauto.
        intros. eapply IH; eauto.
        cbn in IH. eapply IH.
  - rtoProp. destruct brs.
    + simp compile.
    + simp compile.
      unfold EGlobalEnv.lookup_constructor_pars_args, lookup_constructor_args, EGlobalEnv.lookup_constructor in *.
      destruct EGlobalEnv.lookup_inductive as [ [] | ]; cbn -[forallb mapi mapi_rec rev_map map map_InP In]; eauto. unfold Mcase. cbn [wellformed]. rtoProp.
      set (brs_ := p :: brs) in *. repeat split.
      * eauto.
      * clearbody brs_. clear p brs. rewrite map_InP_spec. eapply H in H3; eauto. clear - a IH H2 H3. unfold mapi. generalize 0 at 1, 0 at 1.
        induction a.
        -- cbn; eauto.
        -- cbn -[Mapply_ Mlambda_]. intros. rtoProp. split.
           2:{ eapply IHa. eapply IH.  cbn in H2. rtoProp. eauto. }
           eapply wellformed_Mapply_.
           ++ cbn in IH.
              destruct r as (nms & Hnms & whatever).
              eapply wellformed_Mlambda_.
              cbn in *.
              assert (nms = map (fun nm : BasicAst.name => BasicAst.string_of_name nm) x.1).
              { clear - Hnms. induction Hnms; cbn; f_equal. subst. cbn. reflexivity. eauto. }
              subst. eapply wellformed_subset.
              2:{ eapply IH; eauto. rtoProp. eapply H. }
              rewrite rev_map_spec.
              intros ? ? % in_app_iff. eapply in_app_iff.
              rewrite <- in_rev. eauto.
           ++ clear - H3. destruct x. clear - H3.
              revert H3 n1.
              induction l using rev_ind; intros.
              econstructor.
              rewrite rev_map_spec in *. cbn. rewrite map_app, rev_app_distr. cbn.
              rtoProp. split. eauto. eauto.
  - cbn [wellformed].
    rtoProp. repeat split.
    + cbn. rewrite map_InP_spec. rewrite map_map. rtoProp; split; auto.
      eapply All_forallb. eapply (@All_impl _ (fun '(_, t1) => (wellformed (map (fun '(i, _) => Kernames.string_of_kername i) Σ) (List.rev (map (fun x : EAst.def EAst.term => (BasicAst.string_of_name (EAst.dname x), compile Σ (EAst.dbody x)).1) mfix) ++ Γ0)%list t1))).
      2:{ intros. destruct x. exact X. }
      eapply All_map. cbn.
      assert (nms = (map (fun x0 : EAst.def EAst.term => BasicAst.string_of_name (EAst.dname x0)) mfix)) as ->.
      { clear - a. induction a; cbn; f_equal; eauto.
        destruct x; cbn in *. subst. reflexivity.
      } clear a.
      revert IH.
      unfold EWellformed.wf_fix_gen in H0. cbn in *. rtoProp. clear H0.
      assert (List.length mfix' = List.length mfix) as Hlen.
      { clear - a0. eapply Prelim.Ee.All2_Set_All2 in a0.
        eapply All2_length in a0 as Hlen. lia.
      }
      rewrite Hlen in H2. revert H2.
      generalize mfix at 1 5 6. revert H1. clear.
      induction a0; intros.
      -- econstructor.
      -- cbn in *. rtoProp. econstructor.
         ++ eapply IH; eauto.
         ++ eapply IHa0; eauto. eapply IH.
    + cbn -[in_dec]. unfold EWellformed.wf_fix_gen in H0.
      rtoProp. eapply Nat.ltb_lt in H0.
      rewrite map_InP_spec. rewrite map_map.
      rewrite app_nil_r. destruct in_dec; eauto. exfalso. eapply n0. clear n0.
      rewrite in_app_iff. left.
      assert (List.length mfix' = List.length mfix) as Hlen.
      { clear IH. eapply Prelim.Ee.All2_Set_All2 in a0.
        eapply All2_length in a0 as Hlen. lia.
      }
      rewrite Hlen in H0. 
      eapply nth_error_Some in H0.
      destruct nth_error eqn:Eq; try congruence.
      erewrite nth_error_nth.
      2:{ rewrite nth_error_map, Eq. cbn.
          reflexivity. }
      cbn. eapply nth_error_In in Eq.
      eapply in_map_iff; eexists; split; eauto.
Qed.
