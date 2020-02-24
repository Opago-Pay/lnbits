import uuid
import json
import requests

from flask import jsonify, request, url_for
from lnurl import LnurlWithdrawResponse, encode as lnurl_encode
from datetime import datetime


from lnbits.db import open_ext_db, open_db
from lnbits.extensions.withdraw import withdraw_ext


@withdraw_ext.route("/api/v1/lnurlencode/<urlstr>/<parstr>", methods=["GET"])
def api_lnurlencode(urlstr, parstr):
    """Returns encoded LNURL if web url and parameter gieven."""

    if not urlstr:
        return jsonify({"status": "FALSE"}), 200

    with open_ext_db("withdraw") as withdraw_ext_db:
        user_fau = withdraw_ext_db.fetchall("SELECT * FROM withdraws WHERE uni = ?", (parstr,))
        randar = user_fau[0][15].split(",")
        print(randar)
        # randar = randar[:-1]
        # If "Unique links" selected get correct rand, if not there is only one rand
        if user_fau[0][12] > 0:
            rand = randar[user_fau[0][10] - 1]
        else:
            rand = randar[0]

    url = url_for("withdraw.api_lnurlfetch", _external=True, urlstr=urlstr, parstr=parstr, rand=rand)
    
    if "onion" in url:
        return jsonify({"status": "TRUE", "lnurl": lnurl_encode(TorUrl(url))}), 200
    else:
        return jsonify({"status": "TRUE", "lnurl": lnurl_encode(url.replace("http://", "https://"))}), 200


@withdraw_ext.route("/api/v1/lnurlfetch/<urlstr>/<parstr>/<rand>", methods=["GET"])
def api_lnurlfetch(parstr, urlstr, rand):
    """Returns LNURL json."""

    if not parstr:
        return jsonify({"status": "FALSE", "ERROR": "NO WALL ID"}), 200

    if not urlstr:
        return jsonify({"status": "FALSE", "ERROR": "NO URL"}), 200

    with open_ext_db("withdraw") as withdraw_ext_db:
        user_fau = withdraw_ext_db.fetchall("SELECT * FROM withdraws WHERE uni = ?", (parstr,))
        k1str = uuid.uuid4().hex
        withdraw_ext_db.execute("UPDATE withdraws SET withdrawals = ? WHERE uni = ?", (k1str, parstr,))

        precallback=url_for("withdraw.api_lnurlwithdraw", _external=True, rand=rand)
        if "onion" in precallback:
            precallback=TorUrl(precallback)
        else:
            precallback=precallback.replace("http://", "https://")

    res = LnurlWithdrawResponse(
        callback=precallback,
        k1=k1str,
        min_withdrawable=user_fau[0][8] * 1000,
        max_withdrawable=user_fau[0][7] * 1000,
        default_description="LNbits LNURL withdraw",
    )

    return res.json(), 200


@withdraw_ext.route("/api/v1/lnurlwithdraw/<rand>/", methods=["GET"])
def api_lnurlwithdraw(rand):
    """Pays invoice if passed k1 invoice and rand."""

    k1 = request.args.get("k1")
    pr = request.args.get("pr")

    if not k1:
        return jsonify({"status": "FALSE", "ERROR": "NO k1"}), 200

    if not pr:
        return jsonify({"status": "FALSE", "ERROR": "NO PR"}), 200

    with open_ext_db("withdraw") as withdraw_ext_db:
        user_fau = withdraw_ext_db.fetchall("SELECT * FROM withdraws WHERE withdrawals = ?", (k1,))

        if not user_fau:
            return jsonify({"status": "ERROR", "reason": "NO AUTH"}), 400

        if user_fau[0][10] < 1:
            return jsonify({"status": "ERROR", "reason": "withdraw SPENT"}), 400

        # Check withdraw time
        dt = datetime.now()
        seconds = dt.timestamp()
        secspast = seconds - user_fau[0][14]

        if secspast < user_fau[0][11]:
            return jsonify({"status": "ERROR", "reason": "WAIT " + str(int(user_fau[0][11] - secspast)) + "s"}), 400

        randar = user_fau[0][15].split(",")
        if rand not in randar:
            print("huhhh")
            return jsonify({"status": "ERROR", "reason": "BAD AUTH"}), 400
        if len(randar) > 2:
            randar.remove(rand)
        randstr = ",".join(randar)

        # Update time and increments
        upinc = int(user_fau[0][10]) - 1
        withdraw_ext_db.execute(
            "UPDATE withdraws SET inc = ?, rand = ?, tmestmp = ? WHERE withdrawals = ?", (upinc, randstr, seconds, k1,)
        )

    header = {"Content-Type": "application/json", "Grpc-Metadata-macaroon": str(user_fau[0][4])}
    data = {"payment_request": pr}
    # this works locally but not being served over host, bug, needs fixing
    # r = requests.post(url="https://lnbits.com/api/v1/channels/transactions", headers=header, data=json.dumps(data))
    r = requests.post(url=url_for("api_transactions", _external=True), headers=header, data=json.dumps(data))
    r_json = r.json()

    if "ERROR" in r_json:
        return jsonify({"status": "ERROR", "reason": r_json["ERROR"]}), 400

    with open_ext_db("withdraw") as withdraw_ext_db:
        user_fau = withdraw_ext_db.fetchall("SELECT * FROM withdraws WHERE withdrawals = ?", (k1,))

    return jsonify({"status": "OK"}), 200

@withdraw_ext.route("/api/v1/lnurlmaker", methods=["GET","POST"])
def api_lnurlmaker():

    if request.headers["Content-Type"] != "application/json":
        return jsonify({"ERROR": "MUST BE JSON"}), 400

    with open_db() as db:
        wallet = db.fetchall(
            "SELECT * FROM wallets WHERE adminkey = ?",
            (request.headers["Grpc-Metadata-macaroon"],),
        )
        if not wallet:
            return jsonify({"ERROR": "NO KEY"}), 200

        balance = db.fetchone("SELECT balance/1000 FROM balances WHERE wallet = ?", (wallet[0][0],))[0]
        print(balance)

    postedjson = request.json
    print(postedjson["amount"])
    
    if balance < int(postedjson["amount"]):
        return jsonify({"ERROR": "NOT ENOUGH FUNDS"}), 200

    uni = uuid.uuid4().hex
    rand = uuid.uuid4().hex[0:5]

    with open_ext_db("withdraw") as withdraw_ext_db:
        withdraw_ext_db.execute(
            """
            INSERT OR IGNORE INTO withdraws
            (usr, wal, walnme, adm, uni, tit, maxamt, minamt, spent, inc, tme, uniq, withdrawals, tmestmp, rand)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                wallet[0][2],
                wallet[0][0],
                wallet[0][1],
                wallet[0][3],
                uni,
                postedjson["memo"],
                postedjson["amount"],
                postedjson["amount"],
                0,
                1,
                1,
                0,
                0,
                1,
                rand,
            ),
        )

        user_fau = withdraw_ext_db.fetchone("SELECT * FROM withdraws WHERE uni = ?", (uni,))

        if not user_fau:
            return jsonify({"ERROR": "WITHDRAW NOT MADE"}), 401

    url = url_for("withdraw.api_lnurlfetch", _external=True, urlstr=request.host, parstr=uni, rand=rand)

    if "onion" in url:
        return jsonify({"status": "TRUE", "lnurl": lnurl_encode(url.replace("http://", "https://"))}), 200
    else:
        return jsonify({"status": "TRUE", "lnurl": lnurl_encode(TorUrl(url))}), 200


